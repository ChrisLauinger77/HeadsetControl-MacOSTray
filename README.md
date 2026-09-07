# HeadsetControl-MacOSTray

[![Github Latest Releases](https://img.shields.io/github/downloads/ChrisLauinger77/HeadsetControl-MacOSTray/latest/total)]()
[![Version](https://img.shields.io/github/v/release/ChrisLauinger77/HeadsetControl-MacOSTray)]()
[![Github All Releases](https://img.shields.io/github/downloads/ChrisLauinger77/HeadsetControl-MacOSTray/total.svg)]()
[![license](https://img.shields.io/github/license/ChrisLauinger77/HeadsetControl-MacOSTray)]()

<img src="https://raw.githubusercontent.com/ChrisLauinger77/HeadsetControl-MacOSTray/main/HeadsetControl-MacOSTray/Assets.xcassets/AppIconLight.imageset/AppIconLight.png" alt="Light app icon" width="128"> <img src="https://raw.githubusercontent.com/ChrisLauinger77/HeadsetControl-MacOSTray/main/HeadsetControl-MacOSTray/Assets.xcassets/AppIconDark.imageset/AppIconDark.png" alt="Dark app icon" width="128">

HeadsetControl-MacOSTray is a macOS background application that uses the [headsetcontrol](https://github.com/Sapd/HeadsetControl) library to talk directly to [supported headsets](https://github.com/Sapd/HeadsetControl?tab=readme-ov-file#supported-devices). It provides a convenient status bar menu to display headset battery, chatmix, and device information, and allows quick access to settings and refresh actions.

## Preconditions

1. macOS 14.0 (Sonoma) or later, on Apple Silicon or Intel
2. [Homebrew](https://brew.sh/) only if you install the app with Homebrew Cask or want the optional standalone HeadsetControl CLI

Current release builds are self-contained: they statically embed the pinned
HeadsetControl and HIDAPI versions recorded in
[`build-contract.json`](build-contract.json). Neither library needs to be
installed separately for the tray app to run.

## Installation

1. Optional: Install the standalone [HeadsetControl](https://github.com/Sapd/HeadsetControl)
   CLI if you also want to use it outside the tray app:
   ```sh
   brew tap sapd/headsetcontrol
   brew trust --formula sapd/headsetcontrol/headsetcontrol
   brew install sapd/headsetcontrol/headsetcontrol
   ```
2. Install HeadsetControl-MacOSTray via [Homebrew](https://brew.sh/):
   ```sh
   brew tap ChrisLauinger77/cask
   brew trust --cask chrislauinger77/cask/headsetcontrol-macostray
   brew install --cask chrislauinger77/cask/headsetcontrol-macostray
   ```
3. Follow the first-launch instructions below if macOS blocks the app.

The Cask installs only the self-contained tray app and does not install the
standalone `headsetcontrol` command. Install the official HeadsetControl formula
in step 1 only if you want to use that CLI separately. If you install the app
directly from
[GitHub Releases](https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray/releases),
you can also skip step 1 entirely.

## macOS Security Notice

The universal macOS build supports Apple Silicon and Intel. It is ad-hoc signed but cannot
be notarized without a paid Apple Developer Program membership. The Homebrew Cask
automatically clears the quarantine attribute after installation. If macOS still blocks
the app, or if you installed it directly from GitHub Releases:

1. Control-click `HeadsetControl-MacOSTray.app` in Finder and choose **Open**.
2. Confirm **Open** in the security dialog.

If macOS still blocks the app, open **System Settings → Privacy & Security**, find the
HeadsetControl-MacOSTray message, and choose **Open Anyway**. As a final option, clear
extended attributes from a build you downloaded from this repository and trust:

```sh
xattr -cr "/Applications/HeadsetControl-MacOSTray.app"
```

## Update

Update the app through Homebrew Cask:

```sh
brew upgrade --cask headsetcontrol-macostray
```

New headset support and native-library fixes reach users through a new app
release built with updated pinned HeadsetControl or HIDAPI revisions. Updating
the standalone HeadsetControl formula does **not** update the versions embedded
in an already-built app. Current builds load no Homebrew HeadsetControl or
HIDAPI library on either architecture. See [the build contract](docs/build-contract.md)
for exact inputs and compatibility validation. The application bundle includes
HIDAPI's [BSD-style redistribution notice](HeadsetControl-MacOSTray/HIDAPI-LICENSE.txt).

## Screenshots

Tray

![Screenshot](https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray/blob/main/screenshots/tray.png)

Settings

![General](https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray/blob/main/screenshots/settings1.png)

![Sidetone](https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray/blob/main/screenshots/settings2.png)

![Inactive time](https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray/blob/main/screenshots/settings3.png)

![Equalizer presets](https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray/blob/main/screenshots/settings4.png)

![About](https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray/blob/main/screenshots/settings5.png)

## Features

- Status bar integration for headset battery and chatmix
- Settings panel for configuration
- Refresh button to manually update headset status
- Automatic periodic updates
- Direct integration with libheadsetcontrol through the headsetcontrol C API
- Test mode for checking menu and battery states without a connected headset

## Dynamic Capability Menu

- The tray menu dynamically displays controls based on the capabilities reported by your headset. If a capability is available, a corresponding submenu or action is shown:

- **Sidetone**: Choose from Off, Low, Mid, High, Max. Sets the sidetone level through the headsetcontrol library.
- **Lights**: Toggle headset lights on or off.
- **Inactive Time**: Choose the headset idle timeout from the configured options.
- **Voice Prompts**: Toggle headset voice prompts on or off.
- **Rotate to Mute**: Toggle rotate-to-mute on or off.
- **Equalizer Preset**: If available, shows preset names from the device; otherwise, shows the configured generic presets.

These menu items only appear if the headset reports the corresponding capability through libheadsetcontrol. Selecting an option immediately applies the setting through the library; V2.x no longer launches the `headsetcontrol` command line tool as a subprocess.

## Support

If you like my work, please consider supporting me ! <br><br>
<a href="https://ko-fi.com/ChrisLauinger77" target="_blank">
<img src="https://cdn.prod.website-files.com/5c14e387dab576fe667689cf/670f5a01cf2da94a032117b9_support_me_on_kofi_red-p-500.png" alt="Support me on Ko-fi" width="30%">
</a>

## Build with Xcode

1. Clone this repository:
   ```sh
   git clone https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray.git
   ```
2. For the same native inputs as CI and release, install Xcode 26.3 and CMake,
   then run the [shared build helper](docs/build-contract.md#building-and-testing).
   It fetches the revisions pinned in `build-contract.json`, builds static
   HeadsetControl and HIDAPI archives for the macOS 14.0 floor, runs Debug and
   Release tests, and creates a validated app archive. This path does not use
   Homebrew-provided HeadsetControl or HIDAPI headers and libraries.
3. For quick local development, opening the project directly in Xcode still
   intentionally supports HeadsetControl and HIDAPI headers/libraries installed
   through Homebrew. Install the official HeadsetControl formula when using this
   path. These direct builds are not release artifacts and do not establish the
   pinned dependency contract. SwiftPM source compilation requires Swift 6.1 or
   later; the release toolchain is fixed separately.

## Usage

- The app runs in the background and places an icon in the macOS status bar.
- Click the icon to view headset data.
- Access settings via the dialog to configure update interval, sidetone levels, inactive-time options, equalizer preset names, low-battery notifications, and test mode.
- Use the Refresh button in the settings panel to manually update headset status.

## Troubleshooting

- **No headset data appears:** Check that your headset is supported by the headsetcontrol version embedded in this app release. Updating the app may be necessary.
- **The pinned build helper fails while preparing native dependencies:** Use the
  exact Xcode and CMake prerequisites above and follow the diagnostics from the
  helper. Installing a Homebrew library is not a substitute for its pinned input.
- **A direct local Xcode build fails with `headsetcontrol_c.h not found`:** Install
  the official HeadsetControl formula and make sure its headers are available in
  `/opt/homebrew/include` or `/usr/local/include`. This applies only to the direct
  development path, not to released app bundles or the pinned build helper.

## License

See [LICENSE](LICENSE) for details.

## Credits

- [Sapd](https://github.com/sapd/) for [HeadsetControl](https://github.com/Sapd/HeadsetControl)
