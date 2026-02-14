## Plan: Migrate to libheadsetcontrol

Replace Process-based calls to the headsetcontrol binary with direct libheadsetcontrol integration, update settings/UI copy to remove binary-path configuration, and adjust tests and documentation for the new linkage. This plan adds a small service layer to centralize API usage, wires the library into the Xcode/SwiftPM targets, and updates capability/menu handling to use library data structures, while keeping existing UI behavior and test coverage aligned.

### Steps
1. [ ] Review libheadsetcontrol API and integration method in `README.md` and package metadata; identify Swift module names and JSON/device model equivalents.
2. [ ] Add libheadsetcontrol to build graph in `Package.swift` and Xcode target settings in `HeadsetControl-MacOSTray.xcodeproj/project.pbxproj`, ensuring linkage and embedding as needed.
3. [ ] Introduce a small adapter/service in `HeadsetControl-MacOSTray/AppDelegate.swift` (or a new file) to wrap libheadsetcontrol calls and expose `fetchDevices`, `setSidetone`, `setLights`, `setInactiveTime`, `setVoicePrompts`, `setRotateToMute`, and `setEqualizerPreset`.
4. [ ] Replace Process-based usage in `updateStatusItem` and menu action handlers with adapter calls, mapping capabilities and fields to existing menu logic in `HeadsetControl-MacOSTray/AppDelegate.swift`.
5. [ ] Update settings UI and strings to remove `headsetcontrolPath` and any binary wording in `HeadsetControl-MacOSTray/SettingsView.swift`, `HeadsetControl-MacOSTray/en.lproj/Localizable.strings`, and `HeadsetControl-MacOSTray/de.lproj/Localizable.strings`.
6. [ ] Expand tests to cover adapter defaults and API error handling in `HeadsetControl-MacOSTrayTests/AppDelegateTests.swift`, and update docs in `README.md` to remove binary install steps.

### Further Considerations
1. Should test mode still support `--test-device` behavior? Option A: keep with a mock adapter; Option B: remove; Option C: gate by compile flag.
2. Is libheadsetcontrol distributed as SwiftPM, xcframework, or C library? Confirm to choose linking steps and embedding.
3. Should capability names come from library enums or raw strings? Prefer enums if available; otherwise keep string map.
