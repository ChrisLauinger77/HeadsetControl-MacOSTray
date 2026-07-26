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

External dependency:

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

The app target links `-lheadsetcontrol`, `-lhidapi`, and `-lstdc++`. The app sandbox is disabled because headset/HID access is required.

## Related Repositories And Release Coordination

- `https://github.com/Sapd/HeadsetControl` contains the upstream C library and CLI.
- `https://github.com/Sapd/homebrew-headsetcontrol` provides the official `sapd/headsetcontrol/headsetcontrol` Homebrew formula.
- `https://github.com/ChrisLauinger77/homebrew-cask` owns `Casks/headsetcontrol-macostray.rb` for distributing this app through Homebrew.
- Publishing a release from this repository triggers a `repository_dispatch` event named `update-cask` for `headsetcontrol-macostray`.
- `.github/workflows/update-homebrew-cask.yml` provides the manual fallback for requesting the same cask update.
- Dispatch authentication uses the `HOMEBREW_CASK_PUSH_TOKEN` repository secret. Never print or persist this token.
- Do not maintain a duplicate HeadsetControl formula in the personal cask tap. Use the official Sapd formula.
- When changing release tags, archive names, minimum macOS versions, signing behavior, or installation requirements, verify whether the cask repository and its README must be updated as well.
- Homebrew 6 requires explicit trust for non-official taps. Keep the user-facing trust commands in this repository's README aligned with the cask tap README.

## Release Workflow

When asked to create a release, update the project version, commit the version change, push the commit, and add/push the matching release tag.

Example request:

```text
create release 3.0.0
```

Expected actions:

```sh
git commit -am "Bump version to 3.0.0"
git push
git tag v3.0.0
git push origin v3.0.0
```

## Architecture Notes

- `AppDelegate` is the runtime coordinator. It owns the status item, builds the menu in `menuNeedsUpdate(_:)`, schedules status refreshes, and sends commands to the active `HeadsetControlProviding` implementation.
- `HeadsetControlService` serializes access to the C library with an `NSLock`. Keep C-library calls behind this service or another `HeadsetControlProviding` implementation.
- Test mode is controlled by the `testMode` user default and routed through `hsc_set_test_profile` / `hsc_enable_test_device`. Use it for development without a connected headset.
- Settings are stored in `UserDefaults` through `@AppStorage`. Keep new persisted keys documented by using clear names and sensible defaults.
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

## Worktree Notes

- This repository may have local uncommitted changes. Inspect `git status --short` before editing and do not revert user changes.
- `Products/`, `.build/`, `.swiftpm/`, and screenshots are generally not part of normal source edits unless explicitly requested.
