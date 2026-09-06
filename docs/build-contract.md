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
| HIDAPI 0.15.0 | The macOS implementation uses IOKit/CoreFoundation and pthreads, including older-OS handling around device properties. Separate static archives build at 14.0 for both architectures. Every archive object is checked against that floor. |

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

### HeadsetControl release and snapshot channels

`headsetcontrol.revision` always identifies the exact commit being built.
`channel` is required and accepts only `release` or `snapshot`:

- `release`: `version` names the official upstream release tag, and `revision`
  must equal that tag's commit (annotated tags are dereferenced).
- `snapshot`: `revision` is a deliberately selected upstream commit; `version`
  remains the last official baseline release. It does **not** describe the exact
  snapshot source state. The native version string still uses that baseline;
  use the revision and channel in build provenance to identify the actual source.

Builds fetch only the recorded commit and validate the named baseline tag. They
never resolve upstream HEAD or switch source selection based on the channel.
Offline builds require both the pinned checkout and a previously verified tag;
prepare them using the existing helper's `--fetch-only` option while online.

To select a snapshot, run **Actions → Update HeadsetControl snapshot → Run workflow**
from the default branch. The workflow reads the repository URL from this contract,
resolves HEAD once to a full SHA, and opens a PR changing only `revision` and
`channel`. The version is preserved. The branch name contains the complete target
SHA; repeated requests reuse an open PR or exit if that snapshot is already
selected. Runs are serialized. An interrupted run can reuse an unchanged branch;
conflicting branch content is never force-pushed or deleted automatically.
CI accepts snapshot selection only from the updater's same-repository bot PR
with that deterministic branch name and the two allowed contract-field changes.
Ordinary feature PRs can still build against an already selected snapshot.

The workflow uses the repository's `GITHUB_TOKEN`, so repository settings must
permit Actions to create PRs. If GitHub shows **Approve workflows to run**, approve
those runs, then review normal CI and Codex feedback before merging. See
[GitHub's workflow-trigger rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).
No repository settings are changed by this workflow.

Renovate uses official GitHub releases, not branch/HEAD tracking. One replacement
updates `version`, the release tag's exact commit digest, and `channel: release`
together. Digest-only, rollback and pin-only updates are disabled for this entry
so the snapshot is not continually proposed for replacement by its old baseline.
The inherited schedule/review settings, Actions digest pinning and `automerge: false`
remain in place. HIDAPI dependency management is unchanged.

| Transition | Behavior |
| --- | --- |
| release → release | Renovate proposes a newer official release and its exact tag commit. |
| release → snapshot | The manual workflow selects a SHA and preserves the baseline version. |
| snapshot → snapshot | Another manual request selects a SHA, preserving the baseline and avoiding duplicate PRs. |
| snapshot → release | Renovate proposes a newer official release; CI requires that its commit contains the currently selected snapshot. |

Both existing architecture build checks fetch the current PR base contract and
run `git merge-base --is-ancestor` against the exact upstream snapshot/release
commits. History is fetched shallowly for those two tips and deepened only as
needed. Divergent releases fail CI even if their version/date is newer. Fetch
errors or incomplete ancestry evidence also fail closed. If the base changes
during validation, rerun CI; if it changes afterward, rebase/rerun before merging.
Branch-protection policy is unchanged. Return to release mode by merging a
reviewed, passing Renovate PR once an official release contains the snapshot.

The first adoption PR may only add `channel: release` to the old contract; this
one-time base comparison never permits a missing channel in a build or proposed
contract. Channel metadata is copied into provenance and compared across both
architectures as part of the complete HeadsetControl contract.

Both [Apple Silicon](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)
and [Intel](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
runner inventories expose Xcode 26.3 at `/Applications/Xcode_26.3.app`.
The helper verifies its version **and build number**, failing instead of falling
back to whatever Xcode is the runner default. CMake remains a build tool supplied
by the environment; it does not resolve native source versions. This contract
promises identifiable, repeatable native inputs, not bit-for-bit reproducibility
of ZIPs, signatures or the entire runner image.

headsetcontrol and HIDAPI are linked by explicit paths to `libheadsetcontrol.a`
and `libhidapi.a`, so installed dylibs cannot silently take precedence. HIDAPI
uses upstream `BUILD_SHARED_LIBS=OFF`, separately for arm64 and x86_64.
headsetcontrol receives that architecture's archive through `HIDAPI_LIBRARY`.
Its static archive retains HIDAPI references; the final app and Swift tests link
the two archives once, alongside libc++, IOKit and CoreFoundation. Neither source
dependency is patched and no install-name rewriting is needed.

Each executable slice must define the required headsetcontrol/HIDAPI API symbols
exactly once and have no unresolved HIDAPI symbols. Every member of both static
archives must be inspectable, match its architecture, and declare a deployment
target at or below 14.0. No embedded dylibs or frameworks are packaged. The final
executable may load only the enumerated Apple frameworks, system libraries and
Swift runtime overlays. All Homebrew paths, HIDAPI dylib load commands, temporary
build paths and unexpected runpaths are rejected.

The app is self-contained with respect to both native dependencies. Updating a
user's Homebrew formulas cannot change its HID implementation or headset support.
Fixes to either library require changing the manifest, reviewing the source and
native profile expectations, and rebuilding/releasing the app. The existing Cask
still depends on the headsetcontrol formula, whose HIDAPI dependency serves the
standalone CLI. Removing that Cask dependency is a separate distribution decision;
the automated cask update flow is unchanged.

HIDAPI is redistributed under its BSD-style license. Its full notice is copied
into `Contents/Resources/HIDAPI-LICENSE.txt`; packaging verifies it against the
repository copy. Preserve the upstream copyright/license notices when updating
the pinned version. The application and headsetcontrol retain their GPLv3 terms;
release source availability must include the corresponding native sources and
build scripts identified by this manifest.

## Provenance and packaging gates

`Contents/Resources/BuildProvenance.json` records the application commit,
headsetcontrol and HIDAPI revisions/versions, Xcode version/build, Swift and Clang
version strings, SDK, deployment floor, bundle identity, architecture, native
static archive SHA-256 values, object counts, inspected native deployment, and each
application slice's UUID/deployment/load commands. Release builds require clean
application and dependency checkouts. The helper verifies fetched Git revisions.
Schema 2 explicitly records static HIDAPI linkage; old dynamic-HIDAPI provenance
cannot pass the new packaging gate. Published archives are never migrated or
replaced automatically.

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
validates the architecture ZIP. Tests link the same explicit native archives as
the application, with inherited `DYLD_*` variables removed. A hardware-free probe
checks both native API version strings, verifies that HIDAPI resolves to the
probe executable itself, and rejects any loaded HIDAPI dylib. The helper invokes
the selected Swift toolchain directly. Existing deterministic and C-library
profile tests remain intact.

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
missing/wrong-architecture static archives, a too-new deployment target in any
archive member, uninspectable members, forbidden Homebrew/dylib load paths,
missing/duplicate/unresolved static symbols, final slice mismatch, missing or
changed license notices, real universal assembly/signing and ZIP validation.
Synthetic fixture metadata is never a production build input.
Workflow-only changes run these tests and the complete native/application build.

## Runtime validation still required

On macOS **14.0**, test both Apple Silicon and Intel without Homebrew HIDAPI
available to the app: launch the extracted universal app, open settings/menu, exercise
notifications and permission states, then connect/control/remove/reconnect real
headsets and test sleep/wake/session resume. Repeat on a current stable macOS.
Also verify launch on a machine with Homebrew installed and inspect loaded images
to confirm no installed HIDAPI is loaded. Do not remove libraries needed by a
user's other applications merely to perform this test; use a clean test machine.
Static compatibility checks and hardware-free native profiles cannot establish
those runtime behaviors.

This pass does not change notarization, Developer ID, hardened runtime, the ZIP
format, Intel support, cask dependency strategy or runtime controllers. Changing
the Cask installation policy remains an explicit distribution decision.
