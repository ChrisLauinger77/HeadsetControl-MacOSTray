# HeadsetControl-MacOSTray

[![Github Latest Releases](https://img.shields.io/github/downloads/ChrisLauinger77/HeadsetControl-MacOSTray/latest/total)]()
[![Version](https://img.shields.io/github/v/release/ChrisLauinger77/HeadsetControl-MacOSTray)]()
[![Github All Releases](https://img.shields.io/github/downloads/ChrisLauinger77/HeadsetControl-MacOSTray/total.svg)]()
[![license](https://img.shields.io/github/license/ChrisLauinger77/HeadsetControl-MacOSTray)]()

<img src="https://raw.githubusercontent.com/ChrisLauinger77/HeadsetControl-MacOSTray/main/HeadsetControl-MacOSTray/Assets.xcassets/AppIconLight.imageset/AppIconLight.png" alt="Light app icon" width="128"> <img src="https://raw.githubusercontent.com/ChrisLauinger77/HeadsetControl-MacOSTray/main/HeadsetControl-MacOSTray/Assets.xcassets/AppIconDark.imageset/AppIconDark.png" alt="Dark app icon" width="128">

HeadsetControl-MacOSTray is a macOS background application that uses the [headsetcontrol](https://github.com/Sapd/HeadsetControl) library to talk directly to [supported headsets](https://github.com/Sapd/HeadsetControl?tab=readme-ov-file#supported-devices). It provides a convenient status bar menu to display headset battery, chatmix, and device information, and allows quick access to settings and refresh actions.

## Preconditions

1. MacOS 14 or later
2. [Homebrew](https://brew.sh/) to install headsetcontrol and the app

## Installation

1. Install [headsetcontrol](https://github.com/Sapd/HeadsetControl) via [Homebrew](https://brew.sh/). The app links against the installed library and headers:
   ```sh
   brew tap sapd/headsetcontrol
   brew trust --formula sapd/headsetcontrol/headsetcontrol
   brew install sapd/headsetcontrol/headsetcontrol
   ```

(brew install sapd/headsetcontrol/headsetcontrol --HEAD) when release is not yet available via Homebrew.

2. Install headsetcontrol-macostray via [Homebrew](https://brew.sh/)
   ```sh
   brew tap ChrisLauinger77/cask
   brew trust --cask chrislauinger77/cask/headsetcontrol-macostray
   brew install --cask chrislauinger77/cask/headsetcontrol-macostray
   ```
3. Restart the app after installing or updating headsetcontrol so macOS loads the current library.
4. Follow the first-launch instructions below if macOS blocks the app.

## macOS Security Notice

The universal macOS build supports Apple Silicon and Intel. It is ad-hoc signed but cannot
be notarized without a paid Apple Developer Program membership. On first launch:

1. Control-click `HeadsetControl-MacOSTray.app` in Finder and choose **Open**.
2. Confirm **Open** in the security dialog.

If macOS still blocks the app, open **System Settings → Privacy & Security**, find the
HeadsetControl-MacOSTray message, and choose **Open Anyway**.As a final option, remove the quarantine
attribute from a build you downloaded from this repository and trust:

```sh
xattr -dr com.apple.quarantine "/Applications/HeadsetControl-MacOSTray.app"
```

## Update

1. This app
   ```sh
   brew upgrade
   ```
2. headsetcontrol
   ```sh
   brew reinstall headsetcontrol
   ```
   headsetcontrol is used as a library to talk to supported headsets. It should be updated occasionally even when the app has no updates. The app will use the updated library after restart of the app. Additional headsets might be added as well as new features for existing ones.

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
2. Install headsetcontrol so Xcode can find `headsetcontrol_c.h` and `libheadsetcontrol`.
3. Open the project in Xcode and build.

## Usage

- The app runs in the background and places an icon in the macOS status bar.
- Click the icon to view headset data.
- Access settings via the dialog to configure update interval, sidetone levels, inactive-time options, equalizer preset names, low-battery notifications, and test mode.
- Use the Refresh button in the settings panel to manually update headset status.

## Troubleshooting

- **No headset data appears:** Ensure headsetcontrol is installed, restart the app, and check that your headset is supported by the installed headsetcontrol version.
- **Build fails with `headsetcontrol_c.h not found`:** Install headsetcontrol through Homebrew and make sure the headers are available in `/opt/homebrew/include` or `/usr/local/include`.

## License

See [LICENSE](LICENSE) for details.

## Credits

- [Sapd](https://github.com/sapd/) for [HeadsetControl](https://github.com/Sapd/HeadsetControl)
