# Native build and compatibility contract

The supported floor is **macOS 14.0 (Sonoma)** for arm64 and x86_64. The audit
below found no requirement for 14.6 in current application or pinned native code.
The former app target of 14.6 and project default of 26.0 were configuration,
not an identified runtime/API requirement. Both are now 14.0; SwiftPM already
declared macOS 14. The related Homebrew cask declares `macos: :sonoma`, so its
compatibility declaration needs no change.

Compilation and Mach-O inspection are evidence for this floor, **not proof of
runtime correctness on macOS 14.0**. The local audit machine runs macOS 27 beta;
neither local tests nor the macOS 15 CI runners execute on the oldest supported OS.

## Compatibility audit before changing deployment targets

| Area | Relevant requirement and evidence |
| --- | --- |
| SwiftUI settings | The two-argument `onChange(of:)` in `SettingsView` is available from macOS 14.0. Settings scenes, `AppStorage`, controls, materials and keyboard shortcuts used here predate that floor. SDK availability annotations and a 14.0-targeted build were checked. |
| AppKit menu and lifecycle | Status items, menus, appearance observation, accessory activation, termination replies and workspace lifecycle notifications do not require 14.6. `activate(ignoringOtherApps:)` is deprecated in 14.0, not newly introduced in 14.6. The settings-window selector lookup is existing behavior and needs oldest-OS interaction testing. |
| Foundation/concurrency | Timers in common modes, run-loop scheduling, UserDefaults, locks, worker threads and async tasks support this floor. Type-level `nonisolated` needs a Swift 6.1 compiler ([SE-0449](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0449-nonisolated-for-global-actor-cutoff.md)); it does not impose a 14.6 runtime floor. SwiftPM now states the compiler requirement while retaining Swift 5 language mode. |
| UserNotifications | Async authorization/settings APIs predate Sonoma; notification submission and presentation options used here have no 14.6 requirement. Authorization behavior still needs a real user session. |
| IOKit | Registry matching notifications and `kIOMainPortDefault` (macOS 12+) fit the floor. No second HID control owner was added. |
| headsetcontrol 4.1.0 | The exact source below uses C++20, including `std::format` and `source_location`. It needs a modern Apple Clang/libc++ toolchain; no 14.6-only use was found. Every compiled static archive object is checked for a macOS deployment command at or below 14.0. |
| HIDAPI 0.15.0 | The macOS implementation uses IOKit/CoreFoundation and pthreads, including older-OS handling around device properties. Both architecture dylibs build at 14.0 and link only expected system libraries. |

Before editing the project targets, both native libraries and both full Release
applications were built with compiler deployment target 14.0 using the installed
Xcode 27 beta. Their Mach-O deployment commands, load paths and defined
headsetcontrol symbols were inspected. The repeatable release build uses Xcode
26.3 instead and must pass the same checks in CI. Nothing uses `vtool` or
`install_name_tool` to lower deployment metadata after compilation.

## Exact inputs and runtime model

`build-contract.json` is the authoritative native/toolchain input manifest:

| Input | Value |
| --- | --- |
| Xcode | 26.3, build 17C529 |
| headsetcontrol | 4.1.0, commit `a6e15cc8bc701a9c4dab8ae4e33363f3040628e9` |
| HIDAPI | 0.15.0, commit `d6b2a974608dec3b76fb1e36c189f22b9cf3650c` |
| Deployment target | macOS 14.0 for application, headsetcontrol and HIDAPI |
| Architectures | arm64 and x86_64, built/tested on their native CI runners |

Both [Apple Silicon](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)
and [Intel](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
runner inventories expose Xcode 26.3 at `/Applications/Xcode_26.3.app`.
The helper verifies its version **and build number**, failing instead of falling
back to whatever Xcode is the runner default. CMake remains a build tool supplied
by the environment; it does not resolve native source versions. This contract
promises identifiable, repeatable native inputs, not bit-for-bit reproducibility
of ZIPs, signatures or the entire runner image.

headsetcontrol is linked by an explicit path to `libheadsetcontrol.a`, so an
installed dylib cannot silently take precedence. Defined C API symbols are
required in each final executable slice. Its device implementations are embedded:
updating a user's headsetcontrol formula cannot change an existing application.
Updating headset support requires changing the manifest, reviewing/updating the
native profile expectations, and rebuilding/releasing the app.

HIDAPI is **not bundled**. The staged build dylib has the existing Homebrew runtime
install name established by CMake during compilation:

- arm64: `/opt/homebrew/opt/hidapi/lib/libhidapi.0.dylib`
- x86_64: `/usr/local/opt/hidapi/lib/libhidapi.0.dylib`

These are deliberate architecture-specific runtime paths. Cellar version paths,
the opposite architecture's prefix, temporary build paths, unapproved dylibs and
unexpected runpaths are rejected. Apple frameworks, system libc++/libSystem and
the enumerated Swift runtime overlays are allowed. The installed HIDAPI must
provide the compatible `.0` ABI and support the running OS; its runtime bytes can
differ from the pinned link/test input after an independent Homebrew update.
The formula currently provides Sonoma bottles for both architectures
([formula metadata](https://formulae.brew.sh/api/formula/hidapi.json)). A future
Homebrew ABI or compatibility change requires revalidation. The app does not
promise arbitrary Homebrew prefixes or a self-contained runtime.

## Provenance and packaging gates

`Contents/Resources/BuildProvenance.json` records the application commit,
headsetcontrol and HIDAPI revisions/versions, Xcode version/build, Swift and Clang
version strings, SDK, deployment floor, bundle identity, architecture, native
archive/dylib SHA-256 values, inspected native deployment/linkage, and each
application slice's UUID/deployment/load commands. Release builds require clean
application and dependency checkouts. The helper verifies fetched Git revisions.

Before `lipo`, packaging validates both thin inputs and compares all common
provenance, including the source revision and bundle/build versions. It combines
only the per-architecture records, signs the universal app using the existing
ad-hoc policy, then inspects the executable in the final ZIP and the extracted
signed bundle. Each slice must match its recorded UUID, deployment and linkage.
The publisher additionally checks the application revision against the workflow
commit, tag against app version, and the exact archive SHA-256 using the existing
resumable publication protocol. No published asset is repaired or replaced.

Provenance is build evidence tied to inspected outputs, not an independent
cryptographic attestation of a trusted build machine. Native inputs are hashed;
per-slice UUIDs identify the original linked executables across universal assembly
and ad-hoc signing. Final ZIP checksums protect the publication bytes.

## Building and testing

Use a clean checkout, CMake, and the specified Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer
export PYTHONDONTWRITEBYTECODE=1
python3 -B scripts/build-native-app.py --workspace /tmp/headset-build --arch arm64
```

Use `--arch x86_64` on an Intel runner. The same helper is called by CI and release.
It stages dependencies in the workspace without modifying Homebrew, runs **Debug
and Release `swift test`**, builds the Release app, writes provenance, signs, and
validates the architecture ZIP. Tests load the staged HIDAPI using
`DYLD_LIBRARY_PATH`, so the pinned native profile checks do not silently exercise
an unrelated installed HIDAPI. Existing deterministic and C-library profile tests
remain intact. Production applications keep their external Homebrew load paths.

`--fetch-only` prepares sources; `--offline` requires already verified checkouts.
For local cross-compilation, `--skip-tests` skips execution on the wrong CPU.
`--audit-toolchain` permits a different toolchain/dirty application checkout for
investigation and labels its output audit-only; **release validation rejects it**.
Neither bypass is used by CI or release workflows.

```sh
node --test scripts/tests/*.test.cjs
python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v
bash scripts/create-universal-app.sh arm64.zip x86_64.zip HeadsetControl-MacOSTray.zip
```

Fixtures cover conflicting revisions/versions/toolchains, missing provenance,
too-new native deployment targets, unapproved/wrong-architecture load paths,
missing static symbols, final slice mismatch, real universal assembly/signing and
ZIP validation. Synthetic fixture metadata is never a production build input.
Workflow-only changes run these tests and the complete native/application build.

## Runtime validation still required

On macOS **14.0**, test both Apple Silicon and Intel with the supported Homebrew
HIDAPI installed: launch the extracted universal app, open settings/menu, exercise
notifications and permission states, then connect/control/remove/reconnect real
headsets and test sleep/wake/session resume. Repeat on a current stable macOS.
Test HIDAPI upgrades and missing/incompatible runtime libraries separately.
Static compatibility checks and hardware-free native profiles cannot establish
those runtime behaviors.

This pass does not change notarization, Developer ID, hardened runtime, the ZIP
format, Intel support, cask dependency strategy or runtime controllers. Bundling
HIDAPI or changing installation policy remains an explicit distribution decision.
