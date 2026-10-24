# AGENTS.md

## Project Overview

HeadsetControl-MacOSTray is a macOS status bar app for controlling and monitoring headsets through the `headsetcontrol` C library. The app is mostly SwiftUI for settings, with an AppKit `NSStatusItem` menu managed from `AppDelegate`.

Core paths:

- `HeadsetControl-MacOSTray/HeadsetControl_MacOSTrayApp.swift` - app entry point and Settings scene.
- `HeadsetControl-MacOSTray/AppDelegate.swift` - status bar item, dynamic tray menu, notifications, polling timer, and settings actions.
- `HeadsetControl-MacOSTray/SettingsView.swift` - SwiftUI settings window, persisted with `@AppStorage`.
- `HeadsetControl-MacOSTray/HeadsetControlService.swift` - Swift wrapper around `HeadsetControlCLib`, plus test/mock provider types.
- `HeadsetControlCLib/` - system-library target that imports `headsetcontrol_c.h`.
- `HeadsetControl-MacOSTray/*.lproj/Localizable.strings` - localizations for English, German, Spanish, and French.
- `HeadsetControl-MacOSTrayTests/` - XCTest tests.

## Build And Dependencies

The project can be opened through `HeadsetControl-MacOSTray.xcodeproj` or built as a Swift package via `Package.swift`.

The authoritative CI/release path is `scripts/build-native-app.py` with the exact
inputs in `build-contract.json`; see `docs/build-contract.md`. It builds separate
arm64/x86_64 static headsetcontrol and HIDAPI archives at macOS 14.0 and links them
by explicit paths. The released app needs no Homebrew HIDAPI dylib at runtime.
Keep the archive-member, final linkage, provenance and license-notice checks.

For direct Xcode/SwiftPM development builds outside that release contract:

- Install `headsetcontrol` before building, usually with:
  ```sh
  brew tap sapd/headsetcontrol
  brew trust --formula sapd/headsetcontrol/headsetcontrol
  brew install sapd/headsetcontrol/headsetcontrol --HEAD
  ```
- The C wrapper accepts headers from either `<headsetcontrol/headsetcontrol_c.h>` or `<headsetcontrol_c.h>`.
- Xcode search paths already include `/opt/homebrew/include`, `/usr/local/include`, `/opt/homebrew/lib`, and `/usr/local/lib`.

Prefer Xcode's build tooling when working from Xcode. If using shell commands, useful checks are:

```sh
swift test
xcodebuild -scheme HeadsetControl-MacOSTray -project HeadsetControl-MacOSTray.xcodeproj build
```

The direct Xcode target defaults to `-lheadsetcontrol`, `-lhidapi`, and `-lstdc++`;
the shared build helper overrides those with explicit static archive paths and
required system frameworks. Do not publish direct Homebrew development builds.
The app sandbox is disabled because headset/HID access is required.

## Related Repositories And Release Coordination

- `https://github.com/Sapd/HeadsetControl` contains the upstream C library and CLI.
- `https://github.com/Sapd/homebrew-headsetcontrol` provides the official `sapd/headsetcontrol/headsetcontrol` Homebrew formula.
- `https://github.com/ChrisLauinger77/homebrew-cask` owns `Casks/headsetcontrol-macostray.rb` for distributing this app through Homebrew.
- Successful release publication triggers a `repository_dispatch` event named `update-cask` for `headsetcontrol-macostray`. Candidate builds never dispatch.
- If that dispatch fails after publication, rerun only the `request-cask-update` job of the release workflow; there is no separate manual cask workflow.
- Dispatch authentication uses the `PACKAGE_REPOSITORIES_TOKEN` repository secret. Never print or persist this token.
- Do not maintain a duplicate HeadsetControl formula in the personal cask tap. Use the official Sapd formula.
- When changing release tags, archive names, minimum macOS versions, signing behavior, or installation requirements, verify whether the cask repository and its README must be updated as well.
- Homebrew 6 requires explicit trust for non-official taps. Keep the user-facing trust commands in this repository's README aligned with the cask tap README.

## Release Workflow

Releases use one gated run (see `docs/release-safety.md`): a manual **Release**
workflow run on `main` builds and retains a tested candidate, then waits for
approval of the `release` environment. Approval makes the same run create the
annotated `vX.Y.Z` tag naming that run and publish the candidate's exact bytes
without rebuilding.

When asked to create release `X.Y.Z`, update both `MARKETING_VERSION` entries in
`HeadsetControl-MacOSTray.xcodeproj/project.pbxproj` to `X.Y.Z`. Do not manually
change `CURRENT_PROJECT_VERSION`; the candidate run generates the build number.
Commit and push the version change to `main`, then start the candidate run:

```sh
git commit -am "chore(release): Bump version to 3.0.0"
git push
gh workflow run release.yml --ref main
```

Stop there. The maintainer downloads and tests the `release-assets` artifact while
the run waits, then approves the `release` deployment themselves. Never approve
or reject the deployment, create or push release tags manually, or use “Re-run
all jobs” on a candidate run; build a new candidate instead. Candidates and
pending approvals expire after 30 days.

## Architecture Notes

- `AppDelegate` is the runtime coordinator. It owns the status item, builds the menu in `menuNeedsUpdate(_:)`, schedules status refreshes, and sends commands to the active `HeadsetControlProviding` implementation.
- `HeadsetController` is main-actor isolated and coalesces refresh requests. `HeadsetIOWorker.shared` runs complete C/HID transactions on one dedicated thread. Keep C-library calls behind `HeadsetControlService` / `HeadsetControlProviding`; never call the native provider from AppKit callbacks or nest transactions. The queue/cancellation locks must never surround native calls.
- `HeadsetSnapshot` records the start of the last successful observation. Snapshots expire after the validated refresh interval plus 60 seconds of grace; runtime interval changes reschedule expiration from that observation time. Failed discovery and explicit invalidation still mark cached data non-current immediately. A successful empty result replaces the cache.
- `HeadsetController` debounces recovery events and retries empty/unready discovery at most three times. Lifecycle invalidation rejects pre-event results. Timers and worker-result delivery use main-run-loop common modes so menu tracking remains responsive.
- `HeadsetLifecycleObserver` observes workspace resume and USB registry events without opening HID devices. Stop it with the application. Do not add private lock notifications or change inactive-session monitoring policy implicitly.
- Control menu items carry their device target. Physical controls require a unique, unchanged USB attachment; identical devices cannot be selected by the dependency. Test-mode reads and commands must select only the dependency's reserved test device.
- Shutdown cancels pending work and discards late results, then frees native resources on the HID thread. AppKit uses `terminateLater`; never synchronously wait for HID on the main actor.
- Test mode is controlled by the `testMode` user default and routed through `hsc_set_test_profile` / `hsc_enable_test_device`. Use it for development without a connected headset.
- `AppDefaults.standard` registers and validates the shared settings policy before AppKit or `@AppStorage` reads it. Keep defaults and supported ranges in `AppDefaults`, including test profiles before native integer conversion.
- Discovery, per-device telemetry and commands return typed results. Preserve native error codes; successful empty discovery is not an error. Battery decoding uses the named status constants in headsetcontrol_c.h; keep the native-profile regression test when updating the dependency.
- Low-battery notifications retain first-device eligibility, with suppression per reliable attachment. Only successful submission consumes an opportunity; valid available readings above the threshold rearm it. Do not fabricate identity for ambiguous devices.
- Equalizer menu entries use the ordered native preset count/indices and copied names. Stored names are fallbacks for unnamed supported indices only.
- Menu capabilities are driven by `HeadsetCapability.menuCapabilities` and legacy capability strings such as `CAP_SIDETONE`. If adding a headset feature, update the capability mapping, provider calls, menu construction, settings as needed, and localization files.
- `ContentView.swift` is not the main user experience; the app uses a Settings scene and status bar menu.

## Coding Guidelines

- Follow existing Swift style: 4-space indentation, `PascalCase` types, `camelCase` members, small helper methods for repeated UI or parsing logic.
- Prefer SwiftUI for settings UI and AppKit only where required for status bar/menu behavior.
- Avoid force unwraps except for static constants that are effectively guaranteed, and keep C pointer handling guarded.
- Do not introduce Combine; prefer direct SwiftUI state, notifications already used by the app, or async/await when a new async API is needed.
- Keep hardware-facing logic testable behind `HeadsetControlProviding`.
- Preserve localization. Any new user-visible string should use `NSLocalizedString` and be added to all existing `.lproj/Localizable.strings` files.
- Keep edits scoped. Avoid rewriting project files, generated build files, assets, or localization formatting unless the task requires it.

## Validation

For narrow Swift changes, first use Xcode live diagnostics if available. For broader changes, build the Xcode project. Run tests when touching defaults, parsing, service behavior, or menu logic:

```sh
swift test
```

Hardware behavior may depend on the installed `headsetcontrol` version and connected devices. Prefer test profiles for reproducible checks and note when real-device validation was not performed.

Renovate updates only `build-contract.json`, so script tests must read pinned dependency versions and revisions from the contract instead of hardcoding them. `scripts/tests/test_contract_updates.py` reruns the Python script tests against a simulated dependency update to enforce this.

## Worktree Notes

- This repository may have local uncommitted changes. Inspect `git status --short` before editing and do not revert user changes.
- `Products/`, `.build/`, `.swiftpm/`, and screenshots are generally not part of normal source edits unless explicitly requested.
