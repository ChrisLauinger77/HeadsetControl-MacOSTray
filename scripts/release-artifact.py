#!/usr/bin/env python3
"""Validate release identity without changing packaging or deployment policy."""

import argparse
import json
import plistlib
import re
from pathlib import Path, PurePosixPath
import zipfile

APP_NAME = "HeadsetControl-MacOSTray.app"
EXECUTABLE = "HeadsetControl-MacOSTray"
IDENTIFIER = "org.chrislauinger77.HeadsetControl-MacOSTray"
IDENTITY_KEYS = (
    "CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType",
    "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion",
)


def identity(plist, tag=None):
    result = {key: plist.get(key) for key in IDENTITY_KEYS}
    for key, value in result.items():
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"Missing or invalid bundle identity field: {key}")
    for key, expected in {
        "CFBundleIdentifier": IDENTIFIER,
        "CFBundleExecutable": EXECUTABLE,
        "CFBundlePackageType": "APPL",
    }.items():
        if result[key] != expected:
            raise ValueError(f"Unexpected {key}: {result[key]!r}; expected {expected!r}")
    if tag is not None and tag != "v" + result["CFBundleShortVersionString"]:
        raise ValueError(f"Tag/version mismatch: {tag!r} does not match bundle version "
                         f"{result['CFBundleShortVersionString']!r}")
    return result


def bundle_identity(path, tag=None):
    app = Path(path)
    if app.name != APP_NAME:
        raise ValueError(f"Expected bundle named {APP_NAME}")
    with (app / "Contents/Info.plist").open("rb") as file:
        result = identity(plistlib.load(file), tag)
    executable = app / "Contents/MacOS" / EXECUTABLE
    if not executable.is_file() or executable.is_symlink():
        raise ValueError("Missing or indirect application executable")
    return result


def archive_identity(path, tag=None):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Archive contains duplicate entries")
        for name in names:
            entry = PurePosixPath(name)
            if entry.is_absolute() or ".." in entry.parts or not entry.parts:
                raise ValueError(f"Unsafe archive entry: {name!r}")
            if entry.parts[0] not in (APP_NAME, "__MACOSX"):
                raise ValueError(f"Unexpected archive root: {name!r}")
        plist = plistlib.loads(archive.read(f"{APP_NAME}/Contents/Info.plist"))
        result = identity(plist, tag)
        executable = archive.getinfo(f"{APP_NAME}/Contents/MacOS/{EXECUTABLE}")
        if executable.file_size == 0 or (executable.external_attr >> 16) & 0o170000 == 0o120000:
            raise ValueError("Missing or indirect application executable")
        return result


def compare(actual, expected):
    for key in IDENTITY_KEYS:
        if actual[key] != expected[key]:
            raise ValueError(f"Bundle identity mismatch for {key}: "
                             f"{actual[key]!r} != {expected[key]!r}")


def project_version(path, tag):
    versions = set(re.findall(r'^\s*MARKETING_VERSION = ([^;]+);', Path(path).read_text(), re.MULTILINE))
    if len(versions) != 1:
        raise ValueError("Expected one consistent application marketing version in the Xcode project")
    version = versions.pop().strip('"')
    if tag != "v" + version:
        raise ValueError(f"Tag/version mismatch: {tag!r} does not match application version {version!r}")
    return {"CFBundleShortVersionString": version}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("bundle", "archive", "project"))
    parser.add_argument("path")
    parser.add_argument("--tag")
    parser.add_argument("--match-bundle")
    args = parser.parse_args()
    try:
        reader = {"bundle": bundle_identity, "archive": archive_identity, "project": project_version}[args.kind]
        result = reader(args.path, args.tag)
        if args.match_bundle:
            compare(result, bundle_identity(args.match_bundle, args.tag))
        print(json.dumps(result, sort_keys=True))
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Release artifact validation failed: {error}\n")


if __name__ == "__main__":
    main()
