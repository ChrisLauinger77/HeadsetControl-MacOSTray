import copy
import importlib.util
from pathlib import Path
import sys
import unittest
import tempfile
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
            other = "x86_64" if arch == "arm64" else "arm64"
            for path in (native.CONTRACT["hidapi"]["install_names"][other],
                         "/opt/homebrew/Cellar/hidapi/0.15.0/lib/libhidapi.0.dylib",
                         "/private/tmp/build/libhidapi.0.dylib", "@rpath/libhidapi.0.dylib",
                         "/usr/local/lib/libheadsetcontrol.dylib", "/usr/lib/libUnexpected.dylib",
                         "/System/Library/Frameworks/NewFramework.framework/Versions/A/NewFramework"):
                wrong = copy.deepcopy(info)
                wrong["dependencies"][path] = "0.15.0"
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, "Unexpected"):
                    native.check_linkage(wrong, arch, "app")
            wrong = copy.deepcopy(info)
            wrong["dependencies"][native.CONTRACT["hidapi"]["install_names"][arch]] = "0.14.0"
            with self.assertRaisesRegex(ValueError, "version"):
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
        with patch.object(native, "load_commands", return_value=info), \
                patch.object(native, "run", return_value="                 U _hsc_discover"):
            with self.assertRaisesRegex(ValueError, "not embedded"):
                native.inspect("fixture", "arm64", "app")

    def test_native_probe_checks_versions_and_loaded_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            prefix = work / "arm64"
            loaded = prefix / "lib/libhidapi.0.dylib"
            environment = {"DYLD_LIBRARY_PATH": str(prefix / "lib")}
            valid = f"4.1.0\n0.15.0\n{loaded}"
            with patch.object(builder, "command") as command, \
                    patch.object(builder, "run", side_effect=["/fixture/SDK", valid]) as run:
                builder.verify_test_runtime(work, prefix, "/fixture/clang", "arm64", environment)
                self.assertIn("-mmacosx-version-min=14.0", command.call_args.args)
                self.assertEqual(run.call_args.kwargs["env"], environment)
            for wrong in (valid.replace("4.1.0", "4.2.0"), valid.replace("0.15.0", "0.14.0"),
                          "4.1.0\n0.15.0\n/opt/homebrew/lib/libhidapi.0.dylib"):
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


if __name__ == "__main__":
    unittest.main()
