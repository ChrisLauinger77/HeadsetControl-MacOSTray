# HeadsetControl-MacOSTray

![Screenshot](https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray/blob/main/HeadsetControl-MacOSTray/Assets.xcassets/AppIcon.appiconset/mac128.png)

HeadsetControl-MacOSTray is a macOS background application that visualizes information from the [headsetcontrol](https://github.com/Sapd/HeadsetControl) command line tool. It provides a convenient status bar menu to display headset battery, chatmix, and device information, and allows quick access to settings and refresh actions.

## Screenshots

Tray

![Screenshot](https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray/blob/main/screenshots/tray.png)

Settings

![Screenshot](https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray/blob/main/screenshots/settings.png)

## Features

- Status bar integration for headset battery and chatmix
- Settings panel for configuration
- Refresh button to manually update headset status
- Automatic periodic updates
- Error handling for missing or misconfigured headsetcontrol binary

## Dynamic Capability Menu

- The tray menu now dynamically displays controls based on the capabilities reported by your headset. If a capability is available, a corresponding submenu or action is shown:

- **Sidetone**: Choose from Off, Low, Mid, High, Max. Sets sidetone level via `headsetcontrol -s <level>`.
- **Lights**: Toggle On/Off. Sets lights via `headsetcontrol -l <0|1>`.
- **Inactive Time**: Choose from Off, 5, 15, 30, 45, 60, 75, 90 minutes. Sets timeout via `headsetcontrol -i <minutes>`.
- **Voice Prompts**: Toggle On/Off. Sets voice prompts via `headsetcontrol -v <0|1>`.
- **Rotate to Mute**: Toggle On/Off. Sets rotate-to-mute via `headsetcontrol -r <0|1>`.
- **Equalizer Preset**: If available, shows preset names from the device; otherwise, shows four generic presets. Sets preset via `headsetcontrol -p <index>`.

These menu items only appear if the headset reports the corresponding capability in its JSON output. Selecting an option will immediately apply the setting using the `headsetcontrol` binary.

## Preconditions

1. MacOS 14 or later
2. [homebrew](https://brew.sh/) to install headsetcontrol binary

## Installation

1. Install [headsetcontrol](https://github.com/Sapd/HeadsetControl) via Homebrew:
   ```sh
   brew install sapd/headsetcontrol/headsetcontrol --HEAD
   ```
2. Download the release zip and install it
3. Verify the headsetcontrol binary works in a terminal (headsetcontrol -o json)
4. Check/change settings of the app when the headsetcontrol binary is not found

## Build with Xcode

1. Clone this repository:
   ```sh
   git clone https://github.com/yourusername/HeadsetControl-MacOSTray.git
   ```
2. Open the project in Xcode and build.

## Usage

- The app runs in the background and places an icon in the macOS status bar.
- Click the icon to view headset data.
- Access settings via the dialog to configure update interval, binary path, and test mode.
- Use the Refresh button in the settings panel to manually update headset status.

## Troubleshooting

- **Refresh button does not work:** Ensure you are using the latest version. The app now observes refresh notifications and updates the status when the button is pressed.
- **headsetcontrol binary not found:** Check the path in settings and ensure headsetcontrol is installed.

## License

See [LICENSE](LICENSE) for details.
