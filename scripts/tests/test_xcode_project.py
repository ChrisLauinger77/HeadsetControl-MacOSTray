import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from xcode_project import PROJECT_PATH, bump_marketing_version, marketing_version, read_project


def project_fixture(version="3.1.0", settings=None):
    values = {"MARKETING_VERSION": version} if settings is None else settings
    return '''{
  "configurations": [{"name": "Debug"}, {"name": "Release"},],
  "targets": [{
    "name": "HeadsetControl-MacOSTray",
    "product-type": "application",
    "build-settings": %s,
  },],
}
''' % json.dumps(values, indent=4)


class XcodeProjectTests(unittest.TestCase):
    def test_trailing_commas_preserve_string_contents(self):
        values = {"commas": ", } , ]", "escaped": '\\", }', "nested": [1, {"x": "a,b"}]}
        contents = json.dumps(values)[:-1] + ",}"
        self.assertEqual(read_project(contents), values)
        for invalid in ('{"a": 1,,}', '{"a": 1, "a": 2}', '{"a": [1,,]}'):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                read_project(invalid)

    def test_common_and_per_configuration_version_bumps_preserve_formatting(self):
        for settings in (
            {"MARKETING_VERSION": "3.0.2"},
            {"MARKETING_VERSION[config=Debug]": "3.0.2", "MARKETING_VERSION[config=Release]": "3.0.2"},
        ):
            source = project_fixture(settings={**settings, "OTHER": "3.0.2"})
            updated, old, new = bump_marketing_version(source)
            self.assertEqual((old, new), ("3.0.2", "3.0.3"))
            expected = source.replace('": "3.0.2"', '": "3.0.3"').replace('"OTHER": "3.0.3"', '"OTHER": "3.0.2"')
            self.assertEqual(updated, expected)
            self.assertEqual(marketing_version(updated), new)

    def test_version_gate_rejects_missing_inconsistent_and_conditional_versions(self):
        for settings in (
            {},
            {"MARKETING_VERSION": "3.0"},
            {"MARKETING_VERSION": "03.0.2"},
            {"MARKETING_VERSION": 3},
            {"MARKETING_VERSION[config=Debug]": "3.0.2"},
            {"MARKETING_VERSION[config=Debug]": "3.0.2", "MARKETING_VERSION[config=Release]": "3.0.3"},
            {"MARKETING_VERSION": "3.0.2", "MARKETING_VERSION[sdk=macosx*]": "3.0.3"},
            {"MARKETING_VERSION": "3.0.2", "MARKETING_VERSION[config=Unknown]": "3.0.2"},
        ):
            with self.subTest(settings=settings), self.assertRaises(ValueError):
                bump_marketing_version(project_fixture(settings=settings))

    def test_project_inheritance_and_overrides_are_validated(self):
        project = read_project(project_fixture(settings={}))
        project["build-settings"] = {"MARKETING_VERSION": "3.0.2"}
        source = json.dumps(project)
        self.assertEqual(marketing_version(source), "3.0.2")
        self.assertEqual(bump_marketing_version(source)[1:], ("3.0.2", "3.0.3"))
        project["targets"][0]["build-settings"]["MARKETING_VERSION[config=Release]"] = "3.0.3"
        with self.assertRaisesRegex(ValueError, "consistent"):
            marketing_version(json.dumps(project))

    def test_converted_project_can_be_read_and_bumped_without_other_changes(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / PROJECT_PATH).read_text()
        updated, old, new = bump_marketing_version(source)
        self.assertEqual(marketing_version(source), old)
        self.assertEqual(marketing_version(updated), new)
        self.assertEqual(updated.replace(f'"{new}"', f'"{old}"'), source)


if __name__ == "__main__":
    unittest.main()
