import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from native_contract import CONTRACT, PROVENANCE, PROVENANCE_SCHEMA, HIDAPI_LICENSE, ROOT, inspect
spec = importlib.util.spec_from_file_location("release_artifact", SCRIPTS / "release-artifact.py")
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)

# Synthetic bundle fixtures intentionally need neither the application nor HID.
PLIST = {
    "CFBundleIdentifier": artifact.IDENTIFIER,
    "CFBundleExecutable": artifact.EXECUTABLE,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "3.1.0",
    "CFBundleVersion": "260906.1244",
    "LSMinimumSystemVersion": "14.0",
}


def provenance_fixture(plist=None, arch="arm64", application=None):
    # Synthetic provenance is for fixtures only; production metadata comes from the build helper.
    return {
        "schema": PROVENANCE_SCHEMA, "application_revision": "a" * 40,
        **{key: CONTRACT[key] for key in ("headsetcontrol", "hidapi", "xcode", "macos")},
        "swift": "fixture Swift", "clang": "fixture Clang", "sdk": "26.2",
        "bundle": PLIST if plist is None else plist,
        "slices": {arch: {
            "application": application or {"uuid": "12345678-1234-1234-1234-123456789ABC",
                "minimum_macos": "14.0", "dependencies": {"/usr/lib/libSystem.B.dylib": "1351.0.0"}, "rpaths": []},
            "native": {
                name: {"sha256": checksum * 64, "minimum_macos": "14.0", "kind": "static-archive",
                       "architecture": arch, "object_count": 1}
                for name, checksum in (("headsetcontrol", "b"), ("hidapi", "c"))
            },
        }},
    }


def zip_fixture(plist=None, root=artifact.APP_NAME):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as archive:
        archive.writestr(f"{root}/Contents/Info.plist", plistlib.dumps(PLIST if plist is None else plist))
        archive.writestr(f"{root}/Contents/MacOS/{artifact.EXECUTABLE}", b"executable fixture")
        archive.writestr(f"{root}/{PROVENANCE}", json.dumps(provenance_fixture(plist)))
        archive.writestr(f"{root}/{HIDAPI_LICENSE}", (ROOT / "HeadsetControl-MacOSTray/HIDAPI-LICENSE.txt").read_bytes())
    data.seek(0)
    return data


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        # Identity-only fixtures; real Mach-O inspection is exercised below.
        self.inspection = patch.object(artifact, "validate_executable")
        self.inspection.start()
        self.addCleanup(self.inspection.stop)

    def test_project_version_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project.pbxproj"
            project.write_text("MARKETING_VERSION = 3.1.0;\nMARKETING_VERSION = 3.1.0;\n")
            self.assertEqual(artifact.project_version(project, "v3.1.0"), {"CFBundleShortVersionString": "3.1.0"})
            with self.assertRaisesRegex(ValueError, "Tag/version mismatch"):
                artifact.project_version(project, "v3.1.1")
            project.write_text("MARKETING_VERSION = 3.1.0;\nMARKETING_VERSION = 3.2.0;\n")
            with self.assertRaisesRegex(ValueError, "consistent"):
                artifact.project_version(project, "v3.1.0")

    def test_matching_tag_and_archive(self):
        self.assertEqual(artifact.archive_identity(zip_fixture(), "v3.1.0"), PLIST)

    def test_tag_version_mismatch(self):
        for tag in ("v3.1.1", "3.1.0", "v3.1.0-beta"):
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "Tag/version mismatch"):
                artifact.archive_identity(zip_fixture(), tag)

    def test_cross_architecture_identity_mismatch(self):
        for key in artifact.IDENTITY_KEYS:
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                artifact.compare({**PLIST, key: "different"}, PLIST)

    def test_missing_identity_and_wrong_application(self):
        for key in artifact.IDENTITY_KEYS:
            plist = {**PLIST}
            del plist[key]
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                artifact.archive_identity(zip_fixture(plist))
        with self.assertRaisesRegex(ValueError, "Unexpected archive root"):
            artifact.archive_identity(zip_fixture(root="Other.app"))

    def test_final_archive_cannot_change_identity(self):
        packaged = artifact.archive_identity(zip_fixture({**PLIST, "CFBundleVersion": "other-build"}))
        with self.assertRaisesRegex(ValueError, "CFBundleVersion"):
            artifact.compare(packaged, PLIST)

    def test_unsafe_and_duplicate_entries_are_rejected(self):
        for name in ("../escape", "/absolute", f"{artifact.APP_NAME}/Contents/Info.plist"):
            fixture = zip_fixture()
            with warnings.catch_warnings(), zipfile.ZipFile(fixture, "a") as archive:
                warnings.simplefilter("ignore", UserWarning)  # Intentional corrupt fixture.
                archive.writestr(name, b"bad")
            fixture.seek(0)
            with self.subTest(name=name), self.assertRaises(ValueError):
                artifact.archive_identity(fixture)

    def test_bundled_dylib_and_changed_license_are_rejected(self):
        fixture = zip_fixture()
        with zipfile.ZipFile(fixture, "a") as archive:
            archive.writestr(f"{artifact.APP_NAME}/Contents/Frameworks/libhidapi.0.dylib", b"unexpected")
        fixture.seek(0)
        with self.assertRaisesRegex(ValueError, "bundled runtime"):
            artifact.archive_identity(fixture)
        with self.assertRaisesRegex(ValueError, "redistribution notice"):
            artifact.validate_hidapi_license(b"incomplete")

@unittest.skipUnless(sys.platform == "darwin", "ditto/lipo/codesign integration requires macOS")
class MacPackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="headset packaging fixtures ")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        source = cls.directory / "main.c"
        source.write_text("int hid_init(void); void hsc_discover(void) {}\n"
                          "void hsc_free_headsets(void) {} void hsc_get_battery(void) {}\n"
                          "const char *hsc_version(void) { return \"fixture\"; }\n"
                          "int main(void) { return hid_init(); }\n")
        hid_source = cls.directory / "hid.c"
        hid_source.write_text("int hid_init(void) { return 0; }\n"
                              "const char *hid_version_str(void) { return \"fixture\"; }\n"
                              "void hid_exit(void) {} void hid_enumerate(void) {}\n"
                              "void hid_open_path(void) {} void hid_close(void) {}\n")
        cls.archives = []
        for arch in ("arm64", "x86_64"):
            app = cls.directory / arch / artifact.APP_NAME
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(PLIST))
            hid_object = cls.directory / arch / "hid.o"
            hid = cls.directory / arch / "libhidapi.a"
            cls.run_command(["xcrun", "clang", "-arch", arch, "-mmacosx-version-min=14.0",
                             "-c", str(hid_source), "-o", str(hid_object)])
            cls.run_command(["xcrun", "ar", "rcs", str(hid), str(hid_object)])
            binary = app / "Contents/MacOS" / artifact.EXECUTABLE
            cls.run_command(["xcrun", "clang", "-arch", arch, "-mmacosx-version-min=14.0",
                             str(source), str(hid), "-o", str(binary)])
            (app / "Contents/Resources").mkdir()
            (app / HIDAPI_LICENSE).write_bytes((ROOT / "HeadsetControl-MacOSTray/HIDAPI-LICENSE.txt").read_bytes())
            (app / PROVENANCE).write_text(json.dumps(provenance_fixture(arch=arch, application=inspect(binary, arch, "app"))))
            archive = cls.directory / f"{arch}.zip"
            cls.run_command(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)])
            cls.archives.append(archive)

    @staticmethod
    def run_command(command):
        return subprocess.run(command, check=True, capture_output=True, text=True)

    def package(self, *extra, archives=None):
        output = self.directory / f"{self.id()}.zip"
        result = subprocess.run(["/bin/bash", str(SCRIPTS / "create-universal-app.sh"),
                                 *map(str, archives or self.archives), str(output), *extra],
                                capture_output=True, text=True)
        return result, output

    def test_final_archive_round_trip(self):
        result, output = self.package("v3.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(artifact.archive_identity(output, "v3.1.0"), PLIST)

    def test_publication_uses_real_archive_validator(self):
        result, filename = self.package("v3.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        program = "const {validateArchive} = require(process.argv[1]); " \
                  "const fs = require('node:fs'); " \
                  "console.log(JSON.stringify(validateArchive(fs.readFileSync(process.argv[2]), process.argv[3])));"
        command = ["node", "-e", program, str(SCRIPTS / "release.cjs"), str(filename)]
        # CI's real checkout revision must not be confused with this synthetic source fixture.
        import os
        environment = {key: value for key, value in os.environ.items() if key != "GITHUB_SHA"}
        valid = subprocess.run([*command, "v3.1.0"], capture_output=True, text=True, check=True, env=environment)
        self.assertEqual(json.loads(valid.stdout), PLIST)
        invalid = subprocess.run([*command, "v3.0.0"], capture_output=True, text=True, env=environment)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("Tag/version mismatch", invalid.stderr)

    def test_thin_archive_cannot_be_published(self):
        with self.assertRaisesRegex(ValueError, "both universal"):
            artifact.archive_identity(self.archives[0], universal=True)

    def test_missing_provenance_cannot_be_packaged(self):
        missing = self.directory / "missing-provenance.zip"
        with zipfile.ZipFile(self.archives[1]) as source, zipfile.ZipFile(missing, "w") as destination:
            for entry in source.infolist():
                if not entry.filename.endswith(PROVENANCE):
                    destination.writestr(entry, source.read(entry))
        result, output = self.package(archives=[self.archives[0], missing])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BuildProvenance.json", result.stderr)
        self.assertFalse(output.exists())

    def test_other_application_revision_cannot_be_combined(self):
        mismatched = self.directory / "other-revision.zip"
        with zipfile.ZipFile(self.archives[1]) as source, zipfile.ZipFile(mismatched, "w") as destination:
            for entry in source.infolist():
                data = source.read(entry)
                if entry.filename.endswith(PROVENANCE):
                    provenance = json.loads(data)
                    provenance["application_revision"] = "d" * 40
                    data = json.dumps(provenance).encode()
                destination.writestr(entry, data)
        result, output = self.package(archives=[self.archives[0], mismatched])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("application_revision", result.stderr)
        self.assertFalse(output.exists())

    def test_ci_packaging_without_tag(self):
        result, output = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(artifact.archive_identity(output), PLIST)

    def test_tag_mismatch_does_not_produce_output(self):
        result, output = self.package("v3.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Tag/version mismatch", result.stderr)
        self.assertFalse(output.exists())

    def test_cross_architecture_mismatch_does_not_produce_output(self):
        mismatched = self.directory / "mismatched.zip"
        with zipfile.ZipFile(self.archives[1]) as source, zipfile.ZipFile(mismatched, "w") as destination:
            for entry in source.infolist():
                data = source.read(entry)
                if entry.filename.endswith("Contents/Info.plist"):
                    data = plistlib.dumps({**PLIST, "CFBundleVersion": "different-build"})
                elif entry.filename.endswith(PROVENANCE):
                    provenance = json.loads(data)
                    provenance["bundle"]["CFBundleVersion"] = "different-build"
                    data = json.dumps(provenance).encode()
                destination.writestr(entry, data)
        result, output = self.package("v3.1.0", archives=[self.archives[0], mismatched])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Bundle identity mismatch for CFBundleVersion", result.stderr)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
