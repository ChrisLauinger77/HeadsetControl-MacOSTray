import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    // Sidetone level values from UserDefaults
    var sidetoneLevelsFromSettings: [(String, Int)] {
        let off = UserDefaults.standard.integer(forKey: "sidetoneOff")
        let low = UserDefaults.standard.integer(forKey: "sidetoneLow")
        let mid = UserDefaults.standard.integer(forKey: "sidetoneMid")
        let high = UserDefaults.standard.integer(forKey: "sidetoneHigh")
        let max = UserDefaults.standard.integer(forKey: "sidetoneMax")
        return [
            ("Off", off),
            ("Low", low),
            ("Mid", mid),
            ("High", high),
            ("Max", max)
        ]
    }
    // Handle Equalizer Preset selection
    @objc func setEqualizerPreset(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        let path = UserDefaults.standard.string(forKey: "headsetcontrolPath") ?? "/opt/homebrew/bin/headsetcontrol"
        let testMode = UserDefaults.standard.bool(forKey: "testMode")
        var arguments = ["-p", String(index)]
        if testMode {
            arguments.append("--test-device")
        }
        let task = Process()
        task.launchPath = path
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
        } catch {
            // Optionally handle error
        }
    }
    // Handle Rotate to Mute on/off selection
    @objc func setRotateToMute(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        let path = UserDefaults.standard.string(forKey: "headsetcontrolPath") ?? "/opt/homebrew/bin/headsetcontrol"
        let testMode = UserDefaults.standard.bool(forKey: "testMode")
        var arguments = ["-r", String(value)]
        if testMode {
            arguments.append("--test-device")
        }
        let task = Process()
        task.launchPath = path
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
        } catch {
            // Optionally handle error
        }
    }
    // Handle Voice Prompts on/off selection
    @objc func setVoicePrompts(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        let path = UserDefaults.standard.string(forKey: "headsetcontrolPath") ?? "/opt/homebrew/bin/headsetcontrol"
        let testMode = UserDefaults.standard.bool(forKey: "testMode")
        var arguments = ["-v", String(value)]
        if testMode {
            arguments.append("--test-device")
        }
        let task = Process()
        task.launchPath = path
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
        } catch {
            // Optionally handle error
        }
    }
    // Handle Inactive Time selection
    @objc func setInactiveTime(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        let path = UserDefaults.standard.string(forKey: "headsetcontrolPath") ?? "/opt/homebrew/bin/headsetcontrol"
        let testMode = UserDefaults.standard.bool(forKey: "testMode")
        var arguments = ["-i", String(value)]
        if testMode {
            arguments.append("--test-device")
        }
        let task = Process()
        task.launchPath = path
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
        } catch {
            // Optionally handle error
        }
    }
    // Handle Lights on/off selection
    @objc func setLights(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        let path = UserDefaults.standard.string(forKey: "headsetcontrolPath") ?? "/opt/homebrew/bin/headsetcontrol"
        let testMode = UserDefaults.standard.bool(forKey: "testMode")
        var arguments = ["-l", String(value)]
        if testMode {
            arguments.append("--test-device")
        }
        let task = Process()
        task.launchPath = path
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
        } catch {
            // Optionally handle error
        }
    }
    // Handle Sidetone level selection
    @objc func setSidetoneLevel(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? Int else { return }
        let path = UserDefaults.standard.string(forKey: "headsetcontrolPath") ?? "/opt/homebrew/bin/headsetcontrol"
        let testMode = UserDefaults.standard.bool(forKey: "testMode")
        var arguments = ["-s", String(level)]
        if testMode {
            arguments.append("--test-device")
        }
        let task = Process()
        task.launchPath = path
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
        } catch {
            // Optionally handle error
        }
    }
    var updateInterval: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "updateInterval")
            return value == 0 ? 600 : value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "updateInterval")
        }
    }

    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?
    var settingsWindow: NSWindow?

    var statusUpdateTimer: Timer?
    var latestDevices: [[String: Any]]? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let sfImage = NSImage(systemSymbolName: "headset", accessibilityDescription: "Headset") {
                button.image = sfImage
                button.image?.isTemplate = true
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        statusMenu = menu

        // Observe refresh notification
        NotificationCenter.default.addObserver(self, selector: #selector(handleRefreshNotification), name: .refreshHeadsetStatus, object: nil)

        // Start timer for periodic updates
        startStatusUpdateTimer()
        // Initial update
        updateStatusItem()
    }

    func startStatusUpdateTimer() {
        statusUpdateTimer?.invalidate()
        let interval = Double(updateInterval)
        statusUpdateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateStatusItem()
        }
    }

    @objc func handleRefreshNotification() {
        updateStatusItem()
    }

    func updateStatusItem() {
        let path = UserDefaults.standard.string(forKey: "headsetcontrolPath") ?? "/opt/homebrew/bin/headsetcontrol"
        let testMode = UserDefaults.standard.bool(forKey: "testMode")
        var arguments = ["-o", "json"]
        if testMode {
            arguments.append("--test-device")
        }
        var batteryLevelText: String? = nil
        var devicesResult: [[String: Any]]? = nil
        let task = Process()
        task.launchPath = path
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let devices = json["devices"] as? [[String: Any]], !devices.isEmpty {
                    devicesResult = devices
                    if let battery = devices[0]["battery"] as? [String: Any], let level = battery["level"] as? Int {
                        batteryLevelText = "\(level)%"
                    }
                }
            }
        } catch {
            // Ignore errors for tray icon, but could show error icon/text if desired
        }
        // Update tray icon title with battery level
        DispatchQueue.main.async {
            if let button = self.statusItem?.button {
                if let batteryText = batteryLevelText {
                    button.title = " " + batteryText
                } else {
                    button.title = ""
                }
            }
            self.latestDevices = devicesResult
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let devices = latestDevices, !devices.isEmpty else {
            menu.addItem(withTitle: "No devices found", action: nil, keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Open Settings", action: #selector(openSettings), keyEquivalent: "s")
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            return
        }
        for (idx, device) in devices.enumerated() {
            let deviceName = device["device"] as? String ?? "Unknown Device"
            let vendor = device["vendor"] as? String ?? "Unknown Vendor"
            let product = device["product"] as? String ?? "Unknown Product"
            menu.addItem(withTitle: "Device: \(deviceName)", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Vendor: \(vendor)", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Product: \(product)", action: nil, keyEquivalent: "")
            if let battery = device["battery"] as? [String: Any], let level = battery["level"] as? Int {
                menu.addItem(withTitle: "Battery: \(level)%", action: nil, keyEquivalent: "")
            }
            if let chatmix = device["chatmix"] {
                menu.addItem(withTitle: "Chatmix: \(chatmix)", action: nil, keyEquivalent: "")
            }
            // Add menu items for selected capabilities
            if let capabilities = device["capabilities"] as? [String] {
                let capabilityMap: [(String, String)] = [
                    ("CAP_SIDETONE", "Sidetone"),
                    ("CAP_LIGHTS", "Lights"),
                    ("CAP_INACTIVE_TIME", "Inactive Time"),
                    ("CAP_VOICE_PROMPTS", "Voice Prompts"),
                    ("CAP_ROTATE_TO_MUTE", "Rotate to Mute"),
                    ("CAP_EQUALIZER_PRESET", "Equalizer Preset"),
                    ("CAP_EQUALIZER", "Equalizer")
                ]
                for (cap, title) in capabilityMap {
                    if capabilities.contains(cap) {
                        switch cap {
                        case "CAP_SIDETONE":
                            let sidetoneMenu = NSMenu(title: "Sidetone")
                            for (levelTitle, levelValue) in sidetoneLevelsFromSettings {
                                if levelValue == -1 { continue }
                                let item = NSMenuItem(title: levelTitle, action: #selector(setSidetoneLevel(_:)), keyEquivalent: "")
                                item.target = self
                                item.representedObject = levelValue
                                sidetoneMenu.addItem(item)
                            }
                            let sidetoneMenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                            menu.addItem(sidetoneMenuItem)
                            menu.setSubmenu(sidetoneMenu, for: sidetoneMenuItem)
                        case "CAP_LIGHTS":
                            let lightsMenu = NSMenu(title: "Lights")
                            let lightsOptions = [
                                ("Off", 0),
                                ("On", 1)
                            ]
                            for (optionTitle, optionValue) in lightsOptions {
                                let item = NSMenuItem(title: optionTitle, action: #selector(setLights(_:)), keyEquivalent: "")
                                item.target = self
                                item.representedObject = optionValue
                                lightsMenu.addItem(item)
                            }
                            let lightsMenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                            menu.addItem(lightsMenuItem)
                            menu.setSubmenu(lightsMenu, for: lightsMenuItem)
                        case "CAP_VOICE_PROMPTS":
                            let voicePromptsMenu = NSMenu(title: "Voice Prompts")
                            let voicePromptsOptions = [
                                ("Off", 0),
                                ("On", 1)
                            ]
                            for (optionTitle, optionValue) in voicePromptsOptions {
                                let item = NSMenuItem(title: optionTitle, action: #selector(setVoicePrompts(_:)), keyEquivalent: "")
                                item.target = self
                                item.representedObject = optionValue
                                voicePromptsMenu.addItem(item)
                            }
                            let voicePromptsMenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                            menu.addItem(voicePromptsMenuItem)
                            menu.setSubmenu(voicePromptsMenu, for: voicePromptsMenuItem)
                        case "CAP_ROTATE_TO_MUTE":
                            let rotateToMuteMenu = NSMenu(title: "Rotate to Mute")
                            let rotateToMuteOptions = [
                                ("Off", 0),
                                ("On", 1)
                            ]
                            for (optionTitle, optionValue) in rotateToMuteOptions {
                                let item = NSMenuItem(title: optionTitle, action: #selector(setRotateToMute(_:)), keyEquivalent: "")
                                item.target = self
                                item.representedObject = optionValue
                                rotateToMuteMenu.addItem(item)
                            }
                            let rotateToMuteMenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                            menu.addItem(rotateToMuteMenuItem)
                            menu.setSubmenu(rotateToMuteMenu, for: rotateToMuteMenuItem)
                        case "CAP_INACTIVE_TIME":
                            let inactiveTimeMenu = NSMenu(title: "Inactive Time")
                            let inactiveOptions = [
                                ("Off", 0),
                                ("5 Minutes", 5),
                                ("15 Minutes", 15),
                                ("30 Minutes", 30),
                                ("45 Minutes", 45),
                                ("60 Minutes", 60),
                                ("75 Minutes", 75),
                                ("90 Minutes", 90)
                            ]
                            for (optionTitle, optionValue) in inactiveOptions {
                                let item = NSMenuItem(title: optionTitle, action: #selector(setInactiveTime(_:)), keyEquivalent: "")
                                item.target = self
                                item.representedObject = optionValue
                                inactiveTimeMenu.addItem(item)
                            }
                            let inactiveTimeMenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                            menu.addItem(inactiveTimeMenuItem)
                            menu.setSubmenu(inactiveTimeMenu, for: inactiveTimeMenuItem)
                        case "CAP_EQUALIZER_PRESET":
                            let eqPresetMenu = NSMenu(title: "Equalizer Preset")
                            var presetNames: [String] = []
                            if let count = device["equalizer_presets_count"] as? Int,
                               let presets = device["equalizer_presets"] as? [String: Any],
                               count > 0 {
                                presetNames = Array(presets.keys)
                                presetNames.sort()
                            } else {
                                presetNames = ["Preset 1", "Preset 2", "Preset 3", "Preset 4"]
                            }
                            for (idx, name) in presetNames.enumerated() {
                                let item = NSMenuItem(title: name, action: #selector(setEqualizerPreset(_:)), keyEquivalent: "")
                                item.target = self
                                item.representedObject = idx
                                eqPresetMenu.addItem(item)
                            }
                            let eqPresetMenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                            menu.addItem(eqPresetMenuItem)
                            menu.setSubmenu(eqPresetMenu, for: eqPresetMenuItem)
                        default:
                            print("Unhandled capability: \(cap)")
                        }
                    }
                }
            }
            
            if idx < devices.count - 1 {
                menu.addItem(NSMenuItem.separator())
            }
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: "s")
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func openSettings() {
        guard let mainWindow = NSApplication.shared.windows.first else { return }
        if settingsWindow == nil {
            // Pass a close handler to SettingsView that ends the sheet
            let settingsView = SettingsView(onClose: { [weak self] in
                if let window = self?.settingsWindow {
                    mainWindow.endSheet(window)
                    self?.settingsWindow = nil
                }
            })
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "HeadsetControl-MacOSTray"
            window.setContentSize(NSSize(width: 500, height: 400))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
            mainWindow.beginSheet(window, completionHandler: { _ in
                self.settingsWindow = nil
            })
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
