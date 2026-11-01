"""Read Xcode's JSON project format, including its optional trailing commas."""

import json
import re

PROJECT_PATH = "HeadsetControl-MacOSTray.xcodeproj/project.xcproj"
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
# Match strings first so commas inside string values are never removed.
JSON_TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|,\s*(?=[}\]])')
MARKETING_KEY = re.compile(r"MARKETING_VERSION(?:\[config=([^\]]+)\])?")
MARKETING_VALUE = re.compile(
    r'(?P<prefix>"MARKETING_VERSION(?:\[config=[^"\]]+\])?"\s*:\s*")'
    r'(?P<value>[^"\\]*)(?P<suffix>")'
)


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate Xcode project key: {key}")
        result[key] = value
    return result


def read_project(contents):
    cleaned = JSON_TOKEN.sub(lambda match: match[0] if match[0].startswith('"') else "", contents)
    project = json.loads(cleaned, object_pairs_hook=unique_keys)
    if not isinstance(project, dict):
        raise ValueError("Expected an Xcode project object")
    return project


def marketing_version(contents):
    project = read_project(contents)
    configurations = [item["name"] for item in project["configurations"]]
    if not configurations or len(configurations) != len(set(configurations)):
        raise ValueError("Expected unique Xcode build configurations")
    targets = project["targets"]
    if len(targets) != 1 or targets[0].get("product-type") != "application":
        raise ValueError("Expected one application target in the Xcode project")
    settings = [project.get("build-settings", {}), targets[0].get("build-settings", {})]
    versions = []
    for values in settings:
        for key, value in values.items():
            if key.startswith("MARKETING_VERSION"):
                match = MARKETING_KEY.fullmatch(key)
                if not match or (match[1] is not None and match[1] not in configurations):
                    raise ValueError(f"Unsupported marketing version condition: {key}")
                if not isinstance(value, str) or not VERSION.fullmatch(value):
                    raise ValueError(f"Application marketing version {value!r} is not X.Y.Z")
                versions.append(value)
    for configuration in configurations:
        effective = None
        for values in settings:
            effective = values.get(f"MARKETING_VERSION[config={configuration}]",
                                   values.get("MARKETING_VERSION", effective))
        if effective is None:
            raise ValueError(f"Missing application marketing version for {configuration}")
    if len(set(versions)) != 1:
        raise ValueError("Expected one consistent application marketing version in the Xcode project")
    return versions[0]


def bump_marketing_version(contents):
    old = marketing_version(contents)
    major, minor, patch = old.split(".")
    new = f"{major}.{minor}.{int(patch) + 1}"
    updated, count = MARKETING_VALUE.subn(
        lambda match: match["prefix"] + new + match["suffix"], contents
    )
    if not count or marketing_version(updated) != new:
        raise ValueError("Cannot update application marketing version")
    # A version bump must preserve all unrelated project data and formatting.
    expected = read_project(contents)
    for settings in (expected.get("build-settings", {}), expected["targets"][0].get("build-settings", {})):
        for key in settings:
            if MARKETING_KEY.fullmatch(key):
                settings[key] = new
    if read_project(updated) != expected:
        raise ValueError("Version bump would change unrelated project data")
    return updated, old, new
