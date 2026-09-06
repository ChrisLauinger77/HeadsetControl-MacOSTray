#!/usr/bin/env python3
"""Shared CI/release build. Stages pinned native inputs without installing them."""

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

from native_contract import CONTRACT, ROOT, PROVENANCE, PROVENANCE_SCHEMA, inspect, inspect_native, run, validate_provenance


def command(*args, **kwargs):
    print("+ " + " ".join(map(str, args)), flush=True)
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


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
    command(compiler, "-isysroot", run("xcrun", "--show-sdk-path"),
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
    work = Path(args.workspace).resolve()
    work.mkdir(parents=True, exist_ok=True)
    if args.fetch_only:
        for name in ("headsetcontrol", "hidapi"):
            source(work, name, args.offline)
        return
    xcode_lines = run("xcodebuild", "-version").splitlines()
    xcode = {"version": xcode_lines[0].removeprefix("Xcode "),
             "build": xcode_lines[1].removeprefix("Build version ")}
    if xcode != CONTRACT["xcode"] and not args.audit_toolchain:
        raise ValueError(f"Expected Xcode {CONTRACT['xcode']}; selected {xcode}")
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
        if platform.machine() != arch:
            raise ValueError("Run native integration tests on a runner of the requested architecture")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("DYLD_")}
        verify_test_runtime(work, prefix, compiler, arch, environment)
        # Use the selected toolchain and the same explicit native archives as the app.
        swift = run("xcrun", "--find", "swift")
        for configuration in ("debug", "release"):
            command(swift, "test", "--configuration", configuration,
                    "--scratch-path", work / ("swift-" + arch),
                    "-Xcc", f"-I{prefix}/include",
                    "-Xlinker", prefix / "lib/libheadsetcontrol.a",
                    "-Xlinker", prefix / "lib/libhidapi.a", "-Xlinker", "-lc++",
                    "-Xlinker", "-framework", "-Xlinker", "IOKit",
                    "-Xlinker", "-framework", "-Xlinker", "CoreFoundation",
                    env=environment, cwd=ROOT)

    derived = work / ("app-" + arch)
    command("xcodebuild", "-scheme", "HeadsetControl-MacOSTray",
            "-project", ROOT / "HeadsetControl-MacOSTray.xcodeproj", "-configuration", "Release",
            "-destination", "platform=macOS", "-derivedDataPath", derived, f"ARCHS={arch}",
            f"MACOSX_DEPLOYMENT_TARGET={CONTRACT['macos']}",
            f'HEADER_SEARCH_PATHS="{ROOT}/HeadsetControlCLib" "{prefix}/include"',
            f'LIBRARY_SEARCH_PATHS="{prefix}/lib"',
            f'OTHER_LDFLAGS="{prefix}/lib/libheadsetcontrol.a" "{prefix}/lib/libhidapi.a" -lc++ -framework IOKit -framework CoreFoundation', "build")
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
        "clang": run("xcrun", "clang", "--version").splitlines()[0], "sdk": run("xcrun", "--show-sdk-version"),
        "bundle": {key: plist[key] for key in keys},
        "slices": {arch: {"native": native,
                         "application": inspect(app / "Contents/MacOS/HeadsetControl-MacOSTray", arch, "app")}},
    }
    if args.audit_toolchain:
        # Deliberately rejected by release validation even when the selected Xcode happens to match.
        provenance["audit_only"] = True
    else:
        validate_provenance(provenance, provenance["bundle"], revision)
    (app / PROVENANCE).write_text(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
    command("codesign", "--force", "--deep", "--sign", "-", app)
    command("codesign", "--verify", "--deep", "--strict", app)
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
    parser.add_argument("--fetch-only", action="store_true")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--skip-tests", action="store_true", help="Local cross-compilation only; CI runs tests on each architecture")
    parser.add_argument("--audit-toolchain", action="store_true", help="Local audit only; output cannot pass release validation")
    try:
        build(parser.parse_args())
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Build contract failed: {error}\n")
