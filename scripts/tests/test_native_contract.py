import copy
import importlib.util
from pathlib import Path
import sys
import unittest
import tempfile
import subprocess
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import native_contract as native
from test_release_artifact import PLIST, provenance_fixture
spec = importlib.util.spec_from_file_location("native_builder", Path(native.__file__).with_name("build-native-app.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def commands(minimum="14.0", platform="1"):
    return f"""fixture:
Load command 0
      cmd LC_BUILD_VERSION
 platform {platform}
    minos {minimum}
      sdk 26.2
Load command 1
      cmd LC_UUID
     uuid 12345678-1234-1234-1234-123456789ABC
"""


class NativeContractTests(unittest.TestCase):
    def test_deployment_commands(self):
        self.assertEqual(native.load_commands(commands())["minimum_macos"], "14.0")
        for minimum in ("14.6", "15.0", "26.0"):
            with self.subTest(minimum=minimum), self.assertRaisesRegex(ValueError, "above"):
                native.load_commands(commands(minimum))
        with self.assertRaisesRegex(ValueError, "platform"):
            native.load_commands(commands(platform="2"))
        for output in ("", commands() + commands()):
            with self.assertRaisesRegex(ValueError, "one macOS deployment"):
                native.load_commands(output)

    def test_load_paths_and_versions(self):
        for arch in sorted(native.ARCHES):
            info = provenance_fixture(arch=arch)["slices"][arch]["application"]
            native.check_linkage(info, arch, "app")
            for path in ("/opt/homebrew/opt/hidapi/lib/libhidapi.0.dylib",
                         "/usr/local/opt/hidapi/lib/libhidapi.0.dylib",
                         "/opt/homebrew/Cellar/hidapi/0.15.0/lib/libhidapi.0.dylib",
                         "/private/tmp/build/libhidapi.0.dylib", "@rpath/libhidapi.0.dylib",
                         "@loader_path/../Frameworks/libhidapi.0.dylib", "libhidapi.dylib",
                         "/usr/local/lib/libheadsetcontrol.dylib", "/usr/lib/libUnexpected.dylib",
                         "/System/Library/Frameworks/NewFramework.framework/Versions/A/NewFramework"):
                wrong = copy.deepcopy(info)
                wrong["dependencies"][path] = "0.15.0"
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "Unexpected"):
                    native.check_linkage(wrong, arch, "app")
            wrong = copy.deepcopy(info)
            wrong["rpaths"] = ["/Users/builder/lib"]
            with self.assertRaisesRegex(ValueError, "search paths"):
                native.check_linkage(wrong, arch, "app")

    def test_missing_and_incompatible_provenance(self):
        valid = provenance_fixture()
        native.validate_provenance(valid, PLIST, "a" * 40)
        for key in ("schema", "application_revision", "headsetcontrol", "hidapi", "xcode", "swift", "clang", "sdk", "macos", "slices", "bundle"):
            wrong = copy.deepcopy(valid)
            del wrong[key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                native.validate_provenance(wrong, PLIST)
        with self.assertRaisesRegex(ValueError, "application revision"):
            native.validate_provenance(valid, PLIST, "d" * 40)
        with self.assertRaisesRegex(ValueError, "Audit-only"):
            native.validate_provenance({**valid, "audit_only": True}, PLIST)
        for dependency in ("headsetcontrol", "hidapi"):
            for field in ("revision", "version"):
                wrong = copy.deepcopy(valid)
                wrong[dependency][field] = "different"
                with self.subTest(dependency=dependency, field=field), self.assertRaisesRegex(ValueError, dependency):
                    native.validate_provenance(wrong, PLIST)
        for dependency in ("headsetcontrol", "hidapi"):
            wrong = copy.deepcopy(valid)
            wrong["slices"]["arm64"]["native"][dependency]["minimum_macos"] = "14.6"
            with self.subTest(dependency=dependency), self.assertRaisesRegex(ValueError, "deployment"):
                native.validate_provenance(wrong, PLIST)
        for key, value in (("kind", "dylib"), ("architecture", "x86_64"),
                           ("object_count", 0), ("object_count", True), ("sha256", "invalid")):
            wrong = copy.deepcopy(valid)
            wrong["slices"]["arm64"]["native"]["hidapi"][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                native.validate_provenance(wrong, PLIST)
        with self.assertRaisesRegex(ValueError, "unsupported build provenance"):
            native.validate_provenance({**valid, "schema": 1}, PLIST)

    def test_cross_architecture_provenance(self):
        left = provenance_fixture()
        right = provenance_fixture(arch="x86_64")
        native.compare_provenance(left, right)
        for field in ("application_revision", "headsetcontrol", "hidapi", "xcode", "swift", "clang", "sdk", "macos", "bundle"):
            wrong = copy.deepcopy(right)
            wrong[field] = "different"
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, field):
                native.compare_provenance(left, wrong)

    def test_final_slice_must_match_inspected_input(self):
        data = provenance_fixture()
        with patch.object(native, "architectures", return_value={"arm64", "x86_64"}):
            with self.assertRaisesRegex(ValueError, "architectures"):
                native.validate_executable("fixture", data)
        original = data["slices"]["arm64"]["application"]
        for key, value in (("uuid", "87654321-1234-1234-1234-123456789ABC"),
                           ("minimum_macos", "13.0"), ("dependencies", {})):
            with patch.object(native, "architectures", return_value={"arm64"}), \
                    patch.object(native, "inspect", return_value={**original, key: value}):
                with self.subTest(key=key), self.assertRaisesRegex(ValueError, "slice identity"):
                    native.validate_executable("fixture", data)

    def test_static_embedding_requires_defined_symbols(self):
        info = provenance_fixture()["slices"]["arm64"]["application"]
        names = ("hsc_discover", "hsc_free_headsets", "hsc_get_battery", "hid_init", "hid_exit",
                 "hid_enumerate", "hid_open_path", "hid_close")
        defined = "\n".join(f"000000 T _{name}" for name in names)
        with patch.object(native, "load_commands", return_value=info):
            with patch.object(native, "run", side_effect=["load commands", defined, ""]):
                self.assertEqual(native.inspect("fixture", "arm64", "app"), info)
            for name in names:
                for symbols in (defined.replace(f"T _{name}", f"U _{name}"), defined + f"\n000000 T _{name}"):
                    with patch.object(native, "run", side_effect=["load commands", symbols]):
                        with self.subTest(name=name), self.assertRaisesRegex(ValueError, "not embedded exactly once"):
                            native.inspect("fixture", "arm64", "app")
            with patch.object(native, "run", side_effect=["load commands", defined, "_hid_read_timeout"]):
                with self.assertRaisesRegex(ValueError, "unresolved HIDAPI"):
                    native.inspect("fixture", "arm64", "app")

    def test_native_probe_checks_versions_and_loaded_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            prefix = work / "arm64"
            loaded = work / "native-probe-arm64"
            environment = {}
            valid = f"4.1.0\n0.15.0\n{loaded}"
            with patch.object(builder, "command") as command, \
                    patch.object(builder, "run", side_effect=["/fixture/SDK", valid]) as run:
                builder.verify_test_runtime(work, prefix, "/fixture/clang", "arm64", environment)
                self.assertIn("-mmacosx-version-min=14.0", command.call_args.args)
                self.assertIn(prefix / "lib/libhidapi.a", command.call_args.args)
                self.assertNotIn("-lhidapi", command.call_args.args)
                self.assertEqual(run.call_args.kwargs["env"], environment)
            for wrong in (valid.replace("4.1.0", "4.2.0"), valid.replace("0.15.0", "0.14.0"),
                          "4.1.0\n0.15.0\n/opt/homebrew/lib/libhidapi.0.dylib",
                          f"4.1.0\n0.15.0\n{prefix}/lib/libhidapi.0.dylib"):
                with patch.object(builder, "command"), patch.object(builder, "run", side_effect=["/fixture/SDK", wrong]):
                    with self.assertRaisesRegex(ValueError, "runtime differs"):
                        builder.verify_test_runtime(work, prefix, "/fixture/clang", "arm64", environment)

    def test_workflows_share_build_contract(self):
        root = Path(__file__).resolve().parents[2]
        for name in ("swift.yml", "release.yml"):
            workflow = (root / ".github/workflows" / name).read_text()
            self.assertIn("scripts/build-native-app.py", workflow)
            self.assertIn(f"/Applications/Xcode_{native.CONTRACT['xcode']['version']}.app", workflow)
            self.assertNotIn("--HEAD", workflow)
            self.assertNotIn("--skip-tests", workflow)
            self.assertNotIn("--audit-toolchain", workflow)
        project = (root / "HeadsetControl-MacOSTray.xcodeproj/project.pbxproj").read_text()
        import re
        self.assertEqual(set(re.findall(r"MACOSX_DEPLOYMENT_TARGET = ([^;]+);", project)), {native.CONTRACT["macos"]})


@unittest.skipUnless(sys.platform == "darwin", "Archive inspection requires Mach-O tooling")
class NativeArchiveTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="headset static archive fixtures ")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)

    def archive(self, arch, minimums=("14.0", "14.0")):
        directory = self.directory / arch
        directory.mkdir(exist_ok=True)
        objects = []
        for index, minimum in enumerate(minimums):
            source = directory / f"object{index}.c"
            source.write_text(f"int object{index}(void) {{ return {index}; }}\n")
            obj = source.with_suffix(".o")
            subprocess.run(["xcrun", "clang", "-arch", arch, f"-mmacosx-version-min={minimum}",
                            "-c", str(source), "-o", str(obj)], check=True, capture_output=True)
            objects.append(obj)
        archive = directory / "libhidapi.a"
        subprocess.run(["xcrun", "ar", "rcs", str(archive), *map(str, objects)], check=True, capture_output=True)
        return archive

    def test_static_archives_required_for_each_architecture(self):
        for arch in sorted(native.ARCHES):
            archive = self.archive(arch)
            info = native.inspect_static_archive(archive, arch)
            self.assertEqual(info["architecture"], arch)
            self.assertEqual(info["kind"], "static-archive")
            self.assertEqual(info["object_count"], 2)
            self.assertEqual(info["sha256"], native.digest(archive))
            self.assertEqual(info["minimum_macos"], "14.0")
            with self.assertRaisesRegex(ValueError, "architecture"):
                native.inspect_static_archive(archive, "x86_64" if arch == "arm64" else "arm64")
            prefix = self.directory / f"stage-{arch}"
            (prefix / "lib").mkdir(parents=True)
            (prefix / "lib/libheadsetcontrol.a").write_bytes(archive.read_bytes())
            # A dylib is not an acceptable substitute for the missing static HIDAPI archive.
            (prefix / "lib/libhidapi.0.dylib").write_bytes(b"dylib")
            with self.assertRaisesRegex(ValueError, "Missing static archive.*libhidapi.a"):
                native.inspect_native(prefix, arch)
            (prefix / "lib/libhidapi.a").write_bytes(archive.read_bytes())
            self.assertEqual(set(native.inspect_native(prefix, arch)), {"headsetcontrol", "hidapi"})

    def test_every_archive_object_must_meet_floor(self):
        for arch in sorted(native.ARCHES):
            archive = self.archive(arch, ("14.0", "14.6"))
            with self.subTest(arch=arch), self.assertRaisesRegex(ValueError, "above 14.0"):
                native.inspect_static_archive(archive, arch)

    def test_uninspectable_archive_members_fail_closed(self):
        archive = self.archive("arm64")
        with patch.object(native, "run", side_effect=[commands(), "object0.o\nobject1.o"]):
            with patch.object(native, "architectures", return_value={"arm64"}):
                with self.assertRaisesRegex(ValueError, "Not every static archive object"):
                    native.inspect_static_archive(archive, "arm64")


if __name__ == "__main__":
    unittest.main()
