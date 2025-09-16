# HeadsetControl-MacOSTray

HeadsetControl-MacOSTray is a macOS background application that visualizes information from the [headsetcontrol](https://github.com/Sapd/HeadsetControl) command line tool. It provides a convenient status bar menu to display headset battery, chatmix, and device information, and allows quick access to settings and refresh actions.

## Features
- Status bar integration for headset battery and chatmix
- Settings panel for configuration
- Refresh button to manually update headset status
- Automatic periodic updates
- Error handling for missing or misconfigured headsetcontrol binary

## Installation
1. Install [headsetcontrol](https://github.com/Sapd/HeadsetControl) via Homebrew:
   ```sh
   brew install sapd/headsetcontrol/headsetcontrol --HEAD
   ```
2. Clone this repository:
   ```sh
   git clone https://github.com/yourusername/HeadsetControl-MacOSTray.git
   ```
3. Open the project in Xcode and build.

## Usage
- The app runs in the background and places an icon in the macOS status bar.
- Click the icon to view battery and chatmix status.
- Access settings via the menu to configure update interval, binary path, and test mode.
- Use the Refresh button in the settings panel to manually update headset status.

## Troubleshooting
- **Refresh button does not work:** Ensure you are using the latest version. The app now observes refresh notifications and updates the status when the button is pressed.
- **headsetcontrol binary not found:** Check the path in settings and ensure headsetcontrol is installed.

## License
See [LICENSE](LICENSE) for details.
