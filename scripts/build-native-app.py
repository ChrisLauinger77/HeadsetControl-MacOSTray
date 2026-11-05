#!/usr/bin/env python3
"""Shared CI/release build. Stages pinned native inputs without installing them."""

import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess

from native_contract import (CONTRACT, ROOT, PROVENANCE, PROVENANCE_SCHEMA, architectures, inspect,
                             inspect_native, run, selected_xcode, validate_provenance, validate_xcode)
from dependency_channels import validate_contract, verify_release_tag


BUILD_NUMBER = re.compile(r"[0-9]+(?:\.[0-9]+){0,2}")


def build_number(value):
    if not BUILD_NUMBER.fullmatch(value):
        raise argparse.ArgumentTypeError(
            "build number must contain one to three dot-separated numeric components")
    return value


def command(*args, **kwargs):
    print("+ " + " ".join(map(str, args)), flush=True)
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def test_triple(arch):
    """Run Intel test executables through Rosetta on Apple Silicon build hosts."""
    if platform.machine() != arch:
        if platform.machine() != "arm64" or arch != "x86_64":
            raise ValueError("Unsupported test host/target architecture")
        try:
            run("/usr/bin/arch", "-x86_64", "/usr/bin/true")
        except subprocess.CalledProcessError as error:
            raise ValueError("Intel tests on Apple Silicon require Rosetta 2") from error
    return f"{arch}-apple-macosx{CONTRACT['macos']}"


def swift_tests(swift, work, prefix, arch, configuration, environment, *, skip_build=False, filter=None):
    settings = ["--configuration", configuration, "--triple", test_triple(arch),
                "--sdk", run("xcrun", "--sdk", "macosx", "--show-sdk-path"),
                "--scratch-path", work / ("swift-" + arch)]
    linking = ["-Xcc", f"-I{prefix}/include",
               "-Xlinker", prefix / "lib/libheadsetcontrol.a",
               "-Xlinker", prefix / "lib/libhidapi.a", "-Xlinker", "-lc++",
               "-Xlinker", "-framework", "-Xlinker", "IOKit",
               "-Xlinker", "-framework", "-Xlinker", "CoreFoundation"]
    if platform.machine() == arch:
        options = (["--skip-build"] if skip_build else []) + (["--filter", filter] if filter else [])
        command(swift, "test", *settings, *linking, *options, env=environment, cwd=ROOT)
        return
    # Xcode 27's SwiftPM testing helper is ARM-only. Build with the selected
    # compiler, then launch the universal XCTest runner's Intel slice explicitly.
    if not skip_build:
        command(swift, "build", "--build-tests", *settings, *linking,
                "-Xswiftc", "-enable-testing", env=environment, cwd=ROOT)
    products = Path(run(swift, "build", "--show-bin-path", *settings, env=environment, cwd=ROOT))
    bundle = products / "HeadsetControl-MacOSTrayTests.xctest"
    if architectures(bundle / "Contents/MacOS/HeadsetControl-MacOSTrayTests") != {arch}:
        raise ValueError("Unexpected XCTest bundle architecture")
    options = ["-XCTest", "HeadsetControl_MacOSTrayTests." + filter] if filter else []
    command("/usr/bin/arch", "-x86_64", run("xcrun", "--find", "xctest"),
            *options, bundle, env=environment, cwd=ROOT)


def source(work, name, offline):
    path = work / (name + "-source")
    dependency = CONTRACT[name]
    if not path.exists():
        if offline:
            raise ValueError(f"Missing offline source: {path}")
        command("git", "init", path)
        command("git", "-C", path, "fetch", "--depth=1", dependency["repository"], dependency["revision"])
        command("git", "-C", path, "checkout", "--detach", "FETCH_HEAD")
    if run("git", "-C", path, "rev-parse", "HEAD") != dependency["revision"]:
        raise ValueError(f"Wrong {name} source revision")
    if run("git", "-C", path, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError(f"Dirty {name} source tree")
    if name == "headsetcontrol":
        verify_release_tag(path, dependency, offline)
    return path


def verify_test_runtime(work, prefix, compiler, arch, environment):
    """Query versions/loaded image only; never enumerate or control hardware."""
    probe = work / ("native-probe-" + arch)
    code = probe.with_suffix(".c")
    code.write_text('''#include <stdio.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <headsetcontrol/headsetcontrol_c.h>
#include <hidapi/hidapi.h>
int main(void) {
    Dl_info image;
    if (!dladdr((void *)hid_version_str, &image)) return 1;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *path = _dyld_get_image_name(i);
        const char *name = strrchr(path, '/');
        name = name ? name + 1 : path;
        if (strncmp(name, "libhidapi", 9) == 0 && strstr(name, ".dylib")) return 1;
    }
    printf("%s\\n%s\\n%s\\n", hsc_version(), hid_version_str(), image.dli_fname);
    return 0;
}
''')
    command(compiler, "-isysroot", run("xcrun", "--sdk", "macosx", "--show-sdk-path"),
            "-arch", arch, f"-mmacosx-version-min={CONTRACT['macos']}",
            f"-I{prefix}/include", code, prefix / "lib/libheadsetcontrol.a",
            prefix / "lib/libhidapi.a", "-lc++", "-framework", "IOKit",
            "-framework", "CoreFoundation", "-o", probe)
    actual = run(probe, env=environment).splitlines()
    if (len(actual) != 3 or actual[:2] != [CONTRACT["headsetcontrol"]["version"], CONTRACT["hidapi"]["version"]]
            or Path(actual[2]).resolve() != probe.resolve()):
        raise ValueError(f"Native test runtime differs from staged contract: {actual}")
    print("Verified native API versions and statically embedded HIDAPI", flush=True)


def build(args):
    validate_contract(CONTRACT)
    work = Path(args.workspace).resolve()
    work.mkdir(parents=True, exist_ok=True)
    if args.fetch_only:
        for name in ("headsetcontrol", "hidapi"):
            source(work, name, args.offline)
        return
    xcode = selected_xcode()
    if not args.audit_toolchain:
        validate_xcode(xcode)
    sdk = run("xcrun", "--sdk", "macosx", "--show-sdk-path")
    sdk_version = run("xcrun", "--sdk", "macosx", "--show-sdk-version")
    # Runner images may export a Command Line Tools SDKROOT. All child tools,
    # including xcrun tool discovery, must use the selected Xcode's macOS SDK.
    os.environ["SDKROOT"] = sdk
    if run("git", "-C", ROOT, "status", "--porcelain", "--untracked-files=all") and not args.audit_toolchain:
        raise ValueError("Release provenance requires a clean application checkout")
    revision = run("git", "-C", ROOT, "rev-parse", "HEAD")
    hsc_source = source(work, "headsetcontrol", args.offline)
    hid_source = source(work, "hidapi", args.offline)
    arch = args.arch
    prefix = work / arch
    compiler = run("xcrun", "--find", "clang")
    cxx = run("xcrun", "--find", "clang++")
    common = ["-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_OSX_ARCHITECTURES={arch}",
              f"-DCMAKE_OSX_SYSROOT={sdk}",
              f"-DCMAKE_OSX_DEPLOYMENT_TARGET={CONTRACT['macos']}",
              f"-DCMAKE_C_COMPILER={compiler}", "-DCMAKE_C_FLAGS=-Werror=unguarded-availability-new"]
    hid_build = work / ("hid-" + arch)
    command("cmake", "-S", hid_source, "-B", hid_build, *common,
            f"-DCMAKE_INSTALL_PREFIX={prefix}", "-DBUILD_SHARED_LIBS=OFF", "-DHIDAPI_BUILD_HIDTEST=OFF")
    command("cmake", "--build", hid_build, "--parallel", "4")
    command("cmake", "--install", hid_build)
    hsc_build = work / ("hsc-" + arch)
    command("cmake", "-S", hsc_source, "-B", hsc_build, *common,
            f"-DCMAKE_CXX_COMPILER={cxx}", "-DCMAKE_CXX_FLAGS=-Werror=unguarded-availability-new",
            f"-DHIDAPI_LIBRARY={prefix}/lib/libhidapi.a",
            f"-DHIDAPI_INCLUDE_DIR={prefix}/include/hidapi", "-DBUILD_SHARED_LIBRARY=OFF",
            f"-DHEADSETCONTROL_VERSION={CONTRACT['headsetcontrol']['version']}")
    command("cmake", "--build", hsc_build, "--target", "headsetcontrol_lib", "--parallel", "4")
    shutil.copy2(hsc_build / "libheadsetcontrol.a", prefix / "lib/libheadsetcontrol.a")
    (prefix / "include/headsetcontrol").mkdir(exist_ok=True)
    shutil.copy2(hsc_source / "lib/headsetcontrol_c.h", prefix / "include/headsetcontrol")
    native = inspect_native(prefix, arch)

    if not args.skip_tests:
        test_triple(arch)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("DYLD_")}
        verify_test_runtime(work, prefix, compiler, arch, environment)
        # Use the selected toolchain and the same explicit native archives as the app.
        swift = run("xcrun", "--find", "swift")
        for configuration in ("debug", "release"):
            swift_tests(swift, work, prefix, arch, configuration, environment)

    derived = work / ("app-" + arch)
    xcode_settings = [
        f"ARCHS={arch}",
        f"MACOSX_DEPLOYMENT_TARGET={CONTRACT['macos']}",
        f'HEADER_SEARCH_PATHS="{ROOT}/HeadsetControlCLib" "{prefix}/include"',
        f'LIBRARY_SEARCH_PATHS="{prefix}/lib"',
        f'OTHER_LDFLAGS="{prefix}/lib/libheadsetcontrol.a" "{prefix}/lib/libhidapi.a" -lc++ -framework IOKit -framework CoreFoundation',
    ]
    if args.build_number is not None:
        xcode_settings.append(f"CURRENT_PROJECT_VERSION={args.build_number}")
    command("xcodebuild", "-scheme", "HeadsetControl-MacOSTray",
            "-sdk", "macosx",
            "-project", ROOT / "HeadsetControl-MacOSTray.xcodeproj", "-configuration", "Release",
            "-destination", "platform=macOS", "-derivedDataPath", derived,
            *xcode_settings, "build")
    app = derived / "Build/Products/Release/HeadsetControl-MacOSTray.app"
    # Import the existing identity validator without triggering provenance validation while stamping.
    import plistlib
    with (app / "Contents/Info.plist").open("rb") as file:
        plist = plistlib.load(file)
    keys = ("CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType",
            "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion")
    provenance = {
        "schema": PROVENANCE_SCHEMA, "application_revision": revision,
        **{key: CONTRACT[key] for key in ("headsetcontrol", "hidapi", "macos")},
        "xcode": xcode, "swift": run("xcrun", "swift", "--version").splitlines()[0],
        "clang": run("xcrun", "clang", "--version").splitlines()[0], "sdk": sdk_version,
        "bundle": {key: plist[key] for key in keys},
        "slices": {arch: {"native": native,
                         "application": inspect(app / "Contents/MacOS/HeadsetControl-MacOSTray", arch, "app")}},
    }
    if args.audit_toolchain:
        # Release validation rejects audits even when the selected Xcode meets the minimum.
        provenance["audit_only"] = True
    else:
        validate_provenance(provenance, provenance["bundle"], revision)
    (app / PROVENANCE).write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
    command("codesign", "--force", "--deep", "--sign", "-", app)
    command("codesign", "--verify", "--deep", "--strict", app)
    if not args.skip_tests:
        # Exercise the About reader against the provenance actually embedded in this
        # bundle, using the already-built tests linked to the app's exact archives.
        swift_tests(swift, work, prefix, arch, "release",
                    {**environment, "HEADSETCONTROL_PROVENANCE_PATH": str(app / PROVENANCE)},
                    skip_build=True, filter="NativeDependencyVersionsTests/testLinkedVersionsMatchEmbeddedProvenance")
    archive = work / f"HeadsetControl-MacOSTray-{arch}.zip"
    command("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
    if not args.audit_toolchain:
        command("python3", ROOT / "scripts/release-artifact.py", "archive", archive,
                "--source-revision", revision)
    print(f"Archive: {archive}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), required=True)
    parser.add_argument("--build-number", type=build_number,
                        help="Override CURRENT_PROJECT_VERSION without changing BuildNumber.xcconfig")
    parser.add_argument("--fetch-only", action="store_true")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--skip-tests", action="store_true", help="Local cross-compilation only; CI executes tests for both architectures")
    parser.add_argument("--audit-toolchain", action="store_true", help="Local audit only; output cannot pass release validation")
    try:
        build(parser.parse_args())
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Build contract failed: {error}\n")
