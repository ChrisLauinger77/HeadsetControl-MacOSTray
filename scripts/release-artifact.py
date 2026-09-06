#!/usr/bin/env python3
"""Validate release identity, native provenance, deployment and linkage."""

import argparse
import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path, PurePosixPath
import zipfile

from native_contract import ARCHES, PROVENANCE, compare_provenance, validate_executable, validate_provenance

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


def bundle_identity(path, tag=None, expected_revision=None):
    app = Path(path)
    if app.name != APP_NAME:
        raise ValueError(f"Expected bundle named {APP_NAME}")
    with (app / "Contents/Info.plist").open("rb") as file:
        result = identity(plistlib.load(file), tag)
    executable = app / "Contents/MacOS" / EXECUTABLE
    if not executable.is_file() or executable.is_symlink():
        raise ValueError("Missing or indirect application executable")
    if list(app.rglob("*.dylib")) or list(app.rglob("*.framework")):
        raise ValueError("Unexpected bundled runtime dependency")
    provenance = validate_provenance(json.loads((app / PROVENANCE).read_text()), result, expected_revision)
    validate_executable(executable, provenance)
    return result


def archive_identity(path, tag=None, expected_revision=None, universal=False):
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
            if entry.parts[0] == APP_NAME and any(part.endswith((".dylib", ".framework")) for part in entry.parts):
                raise ValueError("Unexpected bundled runtime dependency")
        plist = plistlib.loads(archive.read(f"{APP_NAME}/Contents/Info.plist"))
        result = identity(plist, tag)
        executable = archive.getinfo(f"{APP_NAME}/Contents/MacOS/{EXECUTABLE}")
        if executable.file_size == 0 or (executable.external_attr >> 16) & 0o170000 == 0o120000:
            raise ValueError("Missing or indirect application executable")
        provenance = validate_provenance(json.loads(archive.read(f"{APP_NAME}/{PROVENANCE}")), result, expected_revision)
        if universal and set(provenance["slices"]) != ARCHES:
            raise ValueError("Publication requires both universal architecture slices")
        # Inspect the executable from the final ZIP, without launching it or extracting arbitrary paths.
        with tempfile.TemporaryDirectory(prefix="headset-macho-") as directory:
            binary = Path(directory) / EXECUTABLE
            binary.write_bytes(archive.read(executable))
            validate_executable(binary, provenance)
        return result


def merge_provenance(arm, intel, output, tag=None):
    compare(bundle_identity(arm, tag), bundle_identity(intel, tag))
    left = json.loads((Path(arm) / PROVENANCE).read_text())
    right = json.loads((Path(intel) / PROVENANCE).read_text())
    compare_provenance(left, right)
    if set(left["slices"]) != {"arm64"} or set(right["slices"]) != {"x86_64"}:
        raise ValueError("Expected exactly one matching input slice per architecture")
    merged = {**left, "slices": {**left["slices"], **right["slices"]}}
    (Path(output) / PROVENANCE).write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n")
    return merged


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
    parser.add_argument("kind", choices=("bundle", "archive", "project", "merge"))
    parser.add_argument("path")
    parser.add_argument("--tag")
    parser.add_argument("--match-bundle")
    parser.add_argument("--other-bundle")
    parser.add_argument("--output-bundle")
    parser.add_argument("--source-revision")
    parser.add_argument("--universal", action="store_true")
    args = parser.parse_args()
    try:
        if args.kind == "merge":
            if not args.other_bundle or not args.output_bundle:
                raise ValueError("Merging requires both --other-bundle and --output-bundle")
            result = merge_provenance(args.path, args.other_bundle, args.output_bundle, args.tag)
        elif args.kind == "project":
            result = project_version(args.path, args.tag)
        else:
            reader = {"bundle": bundle_identity, "archive": archive_identity}[args.kind]
            result = reader(args.path, args.tag, args.source_revision, args.universal) if args.kind == "archive" else reader(args.path, args.tag, args.source_revision)
        if args.match_bundle:
            compare(result, bundle_identity(args.match_bundle, args.tag))
        print(json.dumps(result, sort_keys=True))
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Release artifact validation failed: {error}\n")


if __name__ == "__main__":
    main()
