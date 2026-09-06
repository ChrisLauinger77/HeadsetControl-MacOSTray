"""Inspect build inputs and Mach-O outputs; never repair deployment/load metadata."""

import hashlib
import json
import re
import subprocess
from pathlib import Path
from dependency_channels import validate_contract, validate_headsetcontrol

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = json.loads((ROOT / "build-contract.json").read_text())
PROVENANCE = "Contents/Resources/BuildProvenance.json"
PROVENANCE_SCHEMA = 2
HIDAPI_LICENSE = "Contents/Resources/HIDAPI-LICENSE.txt"
ARCHES = {"arm64", "x86_64"}
FRAMEWORKS = {"AppKit", "Foundation", "CoreFoundation", "IOKit", "SwiftUI", "UserNotifications"}
SWIFT_LIBRARIES = {
    "Core", "CoreAudio", "CoreFoundation", "CoreImage", "Darwin", "Dispatch",
    "IOKit", "Metal", "OSLog", "ObjectiveC", "QuartzCore", "Spatial",
    "UniformTypeIdentifiers", "XPC", "_Concurrency", "os", "simd",
}
SYSTEM_LIBRARIES = {"/usr/lib/libc++.1.dylib", "/usr/lib/libobjc.A.dylib", "/usr/lib/libSystem.B.dylib"}


def run(*args, **kwargs):
    return subprocess.check_output([str(arg) for arg in args], text=True, **kwargs).strip()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value):
        raise ValueError(f"Invalid version: {value!r}")
    return tuple(map(int, (value + ".0").split(".")[:3]))


def load_commands(output):
    """Parse one object's otool -l output. Fail closed on missing deployment data."""
    result = {"dependencies": {}, "rpaths": []}
    builds = []
    for block in re.split(r"Load command \d+\n", output)[1:]:
        command = re.search(r"^\s*cmd (\S+)", block, re.MULTILINE).group(1)
        if command == "LC_BUILD_VERSION":
            platform = re.search(r"^\s*platform (\S+)", block, re.MULTILINE).group(1)
            if platform not in ("1", "MACOS", "macos"):
                raise ValueError(f"Unexpected Mach-O platform: {platform}")
            builds.append(re.search(r"^\s*minos (\S+)", block, re.MULTILINE).group(1))
        elif command == "LC_VERSION_MIN_MACOSX":
            builds.append(re.search(r"^\s*version (\S+)", block, re.MULTILINE).group(1))
        elif command.endswith("DYLIB"):
            name = re.search(r"^\s*name (.+) \(offset \d+\)", block, re.MULTILINE).group(1)
            current = re.search(r"^\s*current version (\S+)", block, re.MULTILINE).group(1)
            if command == "LC_ID_DYLIB":
                result["install_name"] = name
                result["version"] = current
            else:
                result["dependencies"][name] = current
        elif command == "LC_RPATH":
            result["rpaths"].append(re.search(r"^\s*path (.+) \(offset \d+\)", block, re.MULTILINE).group(1))
        elif command == "LC_UUID":
            result["uuid"] = re.search(r"^\s*uuid (\S+)", block, re.MULTILINE).group(1)
    if len(builds) != 1:
        raise ValueError("Expected one macOS deployment command per Mach-O object")
    result["minimum_macos"] = builds[0]
    if version(builds[0]) > version(CONTRACT["macos"]):
        raise ValueError(f"Mach-O requires macOS {builds[0]}, above {CONTRACT['macos']}")
    return result


def system_dependency(name):
    if name in SYSTEM_LIBRARIES:
        return True
    if any(name == f"/usr/lib/swift/libswift{lib}.dylib" for lib in SWIFT_LIBRARIES):
        return True
    return any(name == f"/System/Library/Frameworks/{framework}.framework/Versions/{suffix}/{framework}"
               for framework in FRAMEWORKS for suffix in ("A", "C"))


def check_linkage(info, arch, kind):
    if kind != "app":
        raise ValueError(f"Unexpected linked artifact kind: {kind}")
    for name in info["dependencies"]:
        if not system_dependency(name):
            raise ValueError(f"Unexpected {arch} {kind} dependency: {name}")
    if not re.fullmatch(r"[0-9A-Fa-f-]{36}", info.get("uuid", "")):
        raise ValueError("Missing application Mach-O UUID")
    if set(info["rpaths"]) - {"/usr/lib/swift", "@executable_path/../Frameworks"}:
        raise ValueError(f"Unexpected runtime search paths: {info['rpaths']}")


def architectures(path):
    return set(run("xcrun", "lipo", "-archs", path).split())


def inspect(path, arch, kind):
    info = load_commands(run("xcrun", "otool", "-arch", arch, "-l", path))
    check_linkage(info, arch, kind)
    if kind == "app":
        # These must be defined in the executable, not imported from a dylib.
        symbols = run("xcrun", "nm", "-arch", arch, "-gU", path)
        for library, required in (
            ("headsetcontrol", ("hsc_discover", "hsc_free_headsets", "hsc_get_battery", "hsc_version")),
            ("HIDAPI", ("hid_init", "hid_exit", "hid_enumerate", "hid_open_path", "hid_close", "hid_version_str")),
        ):
            for symbol in required:
                if len(re.findall(rf"\b[Tt] _{symbol}$", symbols, re.MULTILINE)) != 1:
                    raise ValueError(f"{library} is not embedded exactly once: {symbol}")
        undefined = run("xcrun", "nm", "-arch", arch, "-gu", path)
        if re.search(r"\b_hid_\w+", undefined):
            raise ValueError("Unexpected unresolved HIDAPI symbol")
    return info


def inspect_static_archive(static, arch):
    if not static.is_file():
        raise ValueError(f"Missing static archive: {static}")
    if architectures(static) != {arch}:
        raise ValueError(f"Unexpected native architecture: {static}")
    if not static.read_bytes().startswith(b"!<arch>\n"):
        raise ValueError(f"Expected a static archive: {static}")
    output = run("xcrun", "otool", "-l", static)
    # Every archive member must be inspectable. No unverified LTO objects.
    objects = re.split(r"^.+\([^\n]+\):\n", output, flags=re.MULTILINE)[1:]
    members = [name for name in run("xcrun", "ar", "-t", static).splitlines() if not name.startswith("__.SYMDEF")]
    if not objects or len(objects) != len(members):
        raise ValueError(f"Not every static archive object is inspectable: {static}")
    inspected = [load_commands(obj) for obj in objects]
    if any(obj["dependencies"] or obj["rpaths"] or "install_name" in obj for obj in inspected):
        raise ValueError(f"Unexpected dynamic linkage in static archive: {static}")
    return {"kind": "static-archive", "architecture": arch, "object_count": len(objects),
            "sha256": digest(static), "minimum_macos": max((obj["minimum_macos"] for obj in inspected), key=version)}


def inspect_native(prefix, arch):
    return {name: inspect_static_archive(Path(prefix) / f"lib/lib{name}.a", arch)
            for name in ("headsetcontrol", "hidapi")}


def validate_provenance(data, identity, expected_revision=None):
    validate_contract(CONTRACT)
    if not isinstance(data, dict) or data.get("schema") != PROVENANCE_SCHEMA:
        raise ValueError("Missing or unsupported build provenance")
    if data.get("audit_only"):
        raise ValueError("Audit-only build is not eligible for release")
    validate_headsetcontrol(data.get("headsetcontrol"))
    for key in ("headsetcontrol", "hidapi", "xcode", "macos"):
        if data.get(key) != CONTRACT[key]:
            raise ValueError(f"Build provenance does not match contract: {key}")
    revision = data.get("application_revision", "")
    if not re.fullmatch(r"[a-f0-9]{40}", revision) or (expected_revision and revision != expected_revision):
        raise ValueError("Missing or mismatched application revision")
    if data.get("bundle") != identity:
        raise ValueError("Build provenance bundle identity mismatch")
    if identity["LSMinimumSystemVersion"] != CONTRACT["macos"]:
        raise ValueError("Bundle minimum macOS does not match build contract")
    for field in ("swift", "clang", "sdk"):
        if not isinstance(data.get(field), str) or not data[field].strip():
            raise ValueError(f"Missing toolchain provenance: {field}")
    slices = data.get("slices", {})
    if not slices or not set(slices) <= ARCHES:
        raise ValueError("Missing or unexpected architecture provenance")
    for arch, item in slices.items():
        if set(item.get("native", {})) != {"headsetcontrol", "hidapi"}:
            raise ValueError("Missing or unexpected native artifact provenance")
        check_linkage(item["application"], arch, "app")
        for info in (item["application"], *item["native"].values()):
            if version(info["minimum_macos"]) > version(CONTRACT["macos"]):
                raise ValueError("Native/application deployment target exceeds advertised floor")
        for info in item["native"].values():
            if (info.get("kind") != "static-archive" or info.get("architecture") != arch
                    or type(info.get("object_count")) is not int or info["object_count"] < 1):
                raise ValueError("Missing or inconsistent static archive provenance")
            if not re.fullmatch(r"[a-f0-9]{64}", info.get("sha256", "")):
                raise ValueError("Missing native artifact checksum")
    return data


def compare_provenance(left, right):
    for key in set(left) | set(right):
        if key != "slices" and left.get(key) != right.get(key):
            raise ValueError(f"Cross-architecture provenance mismatch: {key}")


def validate_executable(path, provenance):
    if architectures(path) != set(provenance["slices"]):
        raise ValueError("Executable architectures differ from provenance")
    for arch, item in provenance["slices"].items():
        if inspect(path, arch, "app") != item["application"]:
            raise ValueError(f"Final {arch} slice identity/linkage differs from provenance")
