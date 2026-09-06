import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
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
    "LSMinimumSystemVersion": "14.6",
}


def zip_fixture(plist=None, root=artifact.APP_NAME):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as archive:
        archive.writestr(f"{root}/Contents/Info.plist", plistlib.dumps(PLIST if plist is None else plist))
        archive.writestr(f"{root}/Contents/MacOS/{artifact.EXECUTABLE}", b"executable fixture")
    data.seek(0)
    return data


class ArtifactTests(unittest.TestCase):
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

    def test_publication_uses_real_archive_validator(self):
        with tempfile.TemporaryDirectory() as directory:
            filename = Path(directory) / "HeadsetControl-MacOSTray.zip"
            filename.write_bytes(zip_fixture().getvalue())
            program = "const {validateArchive} = require(process.argv[1]); " \
                      "const fs = require('node:fs'); " \
                      "console.log(JSON.stringify(validateArchive(fs.readFileSync(process.argv[2]), process.argv[3])));"
            command = ["node", "-e", program, str(SCRIPTS / "release.cjs"), str(filename)]
            valid = subprocess.run([*command, "v3.1.0"], capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(valid.stdout), PLIST)
            invalid = subprocess.run([*command, "v3.0.0"], capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("Tag/version mismatch", invalid.stderr)


@unittest.skipUnless(sys.platform == "darwin", "ditto/lipo/codesign integration requires macOS")
class MacPackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="headset packaging fixtures ")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        source = cls.directory / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        cls.archives = []
        for arch in ("arm64", "x86_64"):
            app = cls.directory / arch / artifact.APP_NAME
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(PLIST))
            cls.run_command(["xcrun", "clang", "-arch", arch, str(source),
                             "-o", str(app / "Contents/MacOS" / artifact.EXECUTABLE)])
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
        mismatched.write_bytes(zip_fixture({**PLIST, "CFBundleVersion": "different-build"}).getvalue())
        result, output = self.package("v3.1.0", archives=[self.archives[0], mismatched])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Bundle identity mismatch for CFBundleVersion", result.stderr)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
