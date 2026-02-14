import Cocoa
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    // Sidetone level values from UserDefaults
    var sidetoneLevelsFromSettings: [(String, Int)] {
        let off = UserDefaults.standard.integer(forKey: "sidetoneOff")
        let low = UserDefaults.standard.integer(forKey: "sidetoneLow")
        let mid = UserDefaults.standard.integer(forKey: "sidetoneMid")
        let high = UserDefaults.standard.integer(forKey: "sidetoneHigh")
        let max = UserDefaults.standard.integer(forKey: "sidetoneMax")
        return [
            (NSLocalizedString("Off", comment: "Sidetone level Off"), off),
            (NSLocalizedString("Low", comment: "Sidetone level Low"), low),
            (NSLocalizedString("Medium", comment: "Sidetone level Medium"), mid),
            (NSLocalizedString("High", comment: "Sidetone level High"), high),
            (NSLocalizedString("Maximum", comment: "Sidetone level Maximum"), max)
        ]
    }
    private let headsetControlService = HeadsetControlService()

    private func activeHeadsetControlProvider() -> HeadsetControlProviding {
        let testMode = UserDefaults.standard.integer(forKey: "testMode")
        if testMode == 0 {
            return headsetControlService
        }
        return MockHeadsetControlService(deviceIndex: testMode)
    }

    private func runControlAction(_ action: @escaping (HeadsetControlProviding) -> Void) {
        let provider = activeHeadsetControlProvider()
        DispatchQueue.global(qos: .userInitiated).async {
            action(provider)
        }
    }
    // Handle Equalizer Preset selection
    @objc func setEqualizerPreset(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        runControlAction { provider in
            _ = provider.setEqualizerPreset(index: index)
        }
    }
    // Handle Rotate to Mute on/off selection
    @objc func setRotateToMute(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        runControlAction { provider in
            _ = provider.setRotateToMute(enabled: value != 0)
        }
    }
    // Handle Voice Prompts on/off selection
    @objc func setVoicePrompts(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        runControlAction { provider in
            _ = provider.setVoicePrompts(enabled: value != 0)
        }
    }
    // Handle Inactive Time selection
    @objc func setInactiveTime(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        runControlAction { provider in
            _ = provider.setInactiveTime(minutes: value)
        }
    }
    // Handle Lights on/off selection
    @objc func setLights(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        runControlAction { provider in
            _ = provider.setLights(enabled: value != 0)
        }
    }
    // Handle Sidetone level selection
    @objc func setSidetoneLevel(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? Int else { return }
        runControlAction { provider in
            _ = provider.setSidetone(level: level)
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
    var lowBatteryNotificationShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification authorization and set delegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            // Optionally handle granted/error
        }
        UNUserNotificationCenter.current().delegate = self

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

        // Normalize stored equalizer preset names to comma-only (no spaces) for consistency
        let storedRaw = UserDefaults.standard.string(forKey: "equalizerPresets") ?? "Preset 1,Preset 2,Preset 3,Preset 4"
        let storedParts = storedRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalizedStored = storedParts.joined(separator: ",")
        if normalizedStored != storedRaw {
            UserDefaults.standard.set(normalizedStored, forKey: "equalizerPresets")
            #if DEBUG
            NSLog("HeadsetControl: normalized equalizerPresets in UserDefaults to '%@'", normalizedStored)
            #endif
        }
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
        let provider = activeHeadsetControlProvider()
        DispatchQueue.main.async {
            let devicesResult = provider.fetchDevices()
            var batteryLevelText: String? = nil
            if let device = devicesResult.first,
               let battery = device["battery"] as? [String: Any],
               let level = battery["level"] as? Int {
                batteryLevelText = "\(level)%"
                let status = battery["status"] as? String ?? ""
                let notifyOnLowBattery = UserDefaults.standard.bool(forKey: "notifyOnLowBattery")
                if notifyOnLowBattery && ((status == "BATTERY_AVAILABLE" && level <= 25)) && !self.lowBatteryNotificationShown {
                    self.showLowBatteryNotification(level: level)
                    self.lowBatteryNotificationShown = true
                }
                if status == "BATTERY_AVAILABLE" && level > 25 && UserDefaults.standard.integer(forKey: "testMode") == 0 {
                    self.lowBatteryNotificationShown = false
                }
            }
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
    }

    // Helper to format time_to_empty_min into a submenu suffix like " (5h)" or " (<1h)".
    // - Accepts Int/Double/String values from JSON and returns an optional suffix with a leading space.
    private func formatTimeToEmpty(minutesAny: Any?) -> String? {
        guard let value = minutesAny else { return nil }
        var minutes: Int?
        if let m = value as? Int {
            minutes = m
        } else if let m = value as? Double {
            minutes = Int(m)
        } else if let m = value as? String, let mi = Int(m) {
            minutes = mi
        } else {
            return nil
        }
        guard let mins = minutes, mins > 0 else { return nil }
        if mins < 60 {
            return " (<1h)"
        }
        let hours = mins / 60 // floor division as requested
        return " (\(hours)h)"
    }

    private let inactiveTimeOptionsDefault: [Int] = [1, 2, 5, 10, 15, 30, 45, 60, 75, 90]
    private lazy var inactiveTimeOptionsAllowed: Set<Int> = Set(inactiveTimeOptionsDefault)

    private var inactiveTimeMinutesFromSettings: [Int] {
        let defaultRaw = inactiveTimeOptionsDefault.map(String.init).joined(separator: ",")
        let raw = UserDefaults.standard.string(forKey: "inactiveTimeOptions") ?? defaultRaw
        let parsed = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let filtered = parsed.filter { inactiveTimeOptionsAllowed.contains($0) }
        return Array(Set(filtered)).sorted()
    }

    private func inactiveTimeLabel(for minutes: Int) -> String {
        switch minutes {
        case 1:
            return NSLocalizedString("1 Minute", comment: "Inactive Time 1 minute option")
        case 2:
            return NSLocalizedString("2 Minutes", comment: "Inactive Time 2 minutes option")
        case 5:
            return NSLocalizedString("5 Minutes", comment: "Inactive Time 5 minutes option")
        case 10:
            return NSLocalizedString("10 Minutes", comment: "Inactive Time 10 minutes option")
        case 15:
            return NSLocalizedString("15 Minutes", comment: "Inactive Time 15 minutes option")
        case 30:
            return NSLocalizedString("30 Minutes", comment: "Inactive Time 30 minutes option")
        case 45:
            return NSLocalizedString("45 Minutes", comment: "Inactive Time 45 minutes option")
        case 60:
            return NSLocalizedString("60 Minutes", comment: "Inactive Time 60 minutes option")
        case 75:
            return NSLocalizedString("75 Minutes", comment: "Inactive Time 75 minutes option")
        case 90:
            return NSLocalizedString("90 Minutes", comment: "Inactive Time 90 minutes option")
        default:
            return "\(minutes)"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let devices = latestDevices, !devices.isEmpty else {
            menu.addItem(withTitle: NSLocalizedString("No devices found", comment: "No devices found message"), action: nil, keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Settings...", comment: "Settings menu item"), action: #selector(openSettings), keyEquivalent: "s")
            menu.addItem(withTitle: NSLocalizedString("Quit", comment: "Quit menu item"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            return
        }
        for (idx, device) in devices.enumerated() {
            let deviceName = device["device"] as? String ?? "Unknown Device"
            let vendor = device["vendor"] as? String ?? "Unknown Vendor"
            let product = device["product"] as? String ?? "Unknown Product"
            menu.addItem(withTitle: String(format: "%@: %@", NSLocalizedString("Device", comment: "Device label"), deviceName), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: String(format: "%@: %@", NSLocalizedString("Vendor", comment: "Vendor label"), vendor), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: String(format: "%@: %@", NSLocalizedString("Product", comment: "Product label"), product), action: nil, keyEquivalent: "")
            if let battery = device["battery"] as? [String: Any], let level = battery["level"] as? Int {
                // Append time-to-empty in hours (submenu only) when available. Use floor rounding and "h" suffix; show "<1h" for under 60 minutes.
                let suffix = formatTimeToEmpty(minutesAny: battery["time_to_empty_min"])
                let title = String(format: "%@: %d%%%@", NSLocalizedString("Battery", comment: "Battery label"), level, suffix ?? "")
                menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            }
            if let chatmix = device["chatmix"] {
                menu.addItem(withTitle: String(format: "%@: %@", NSLocalizedString("Chatmix", comment: "Chatmix label"), String(describing: chatmix)), action: nil, keyEquivalent: "")
            }
            // Add menu items for selected capabilities
            if let capabilities = device["capabilities"] as? [String] {
                let capabilityMap: [(String, String)] = [
                    ("CAP_SIDETONE", NSLocalizedString("Sidetone", comment: "Sidetone capability")),
                    ("CAP_LIGHTS", NSLocalizedString("Lights", comment: "Lights capability")),
                    ("CAP_INACTIVE_TIME", NSLocalizedString("Inactive Time", comment: "Inactive Time capability")),
                    ("CAP_VOICE_PROMPTS", NSLocalizedString("Voice Prompts", comment: "Voice Prompts capability")),
                    ("CAP_ROTATE_TO_MUTE", NSLocalizedString("Rotate to Mute", comment: "Rotate to Mute capability")),
                    ("CAP_EQUALIZER_PRESET", NSLocalizedString("Equalizer Preset", comment: "Equalizer Preset capability")),
                    ("CAP_EQUALIZER", NSLocalizedString("Equalizer", comment: "Equalizer capability"))
                ]
                for (cap, title) in capabilityMap {
                    if capabilities.contains(cap) {
                        switch cap {
                        case "CAP_SIDETONE":
                            let sidetoneMenu = NSMenu(title: NSLocalizedString("Sidetone", comment: "Sidetone capability"))
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
                            let lightsMenu = NSMenu(title: NSLocalizedString("Lights", comment: "Lights capability"))
                            let lightsOptions = [
                                (NSLocalizedString("Off", comment: "Lights off option"), 0),
                                (NSLocalizedString("On", comment: "Lights on option"), 1)
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
                            let voicePromptsMenu = NSMenu(title: NSLocalizedString("Voice Prompts", comment: "Voice Prompts capability"))
                            let voicePromptsOptions = [
                                (NSLocalizedString("Off", comment: "Voice Prompts off option"), 0),
                                (NSLocalizedString("On", comment: "Voice Prompts on option"), 1)
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
                            let rotateToMuteMenu = NSMenu(title: NSLocalizedString("Rotate to Mute", comment: "Rotate to Mute capability"))
                            let rotateToMuteOptions = [
                                (NSLocalizedString("Off", comment: "Rotate to Mute off option"), 0),
                                (NSLocalizedString("On", comment: "Rotate to Mute on option"), 1)
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
                            let inactiveTimeMenu = NSMenu(title: NSLocalizedString("Inactive Time", comment: "Inactive Time capability"))
                            let selectedMinutes = inactiveTimeMinutesFromSettings
                            let inactiveOptions = [(NSLocalizedString("Off", comment: "Inactive Time off option"), 0)] + selectedMinutes.map {
                                (inactiveTimeLabel(for: $0), $0)
                            }
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
                            let eqPresetMenu = NSMenu(title: NSLocalizedString("Equalizer Preset", comment: "Equalizer Preset capability"))
                            var presetNames: [String] = []
                            if let count = device["equalizer_presets_count"] as? Int,
                               let presets = device["equalizer_presets"] as? [String: Any],
                               count > 0 {
                                // Preserve device-reported preset order (do not sort)
                                let reportedKeys = Array(presets.keys).map { String($0) }

                                // Read stored presets (support both comma and comma+space formats) and normalize
                                let storedRaw = UserDefaults.standard.string(forKey: "equalizerPresets") ?? "Preset 1,Preset 2,Preset 3,Preset 4"
                                let storedParts = storedRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                let normalizedStored = storedParts.joined(separator: ",")
                                if normalizedStored != storedRaw {
                                    UserDefaults.standard.set(normalizedStored, forKey: "equalizerPresets")
                                    #if DEBUG
                                    NSLog("HeadsetControl: normalized equalizerPresets in UserDefaults to '%@'", normalizedStored)
                                    #endif
                                }

                                // Localize preset names from device (preserve device order)
                                presetNames = reportedKeys.map { NSLocalizedString($0, comment: "Equalizer preset from device") }
                            } else {
                                // Use user-defined preset names from settings, fallback to defaults if empty
                                let stored = UserDefaults.standard.string(forKey: "equalizerPresets") ?? "Preset 1,Preset 2,Preset 3,Preset 4"
                                let names = stored.split(separator: ",").map { NSLocalizedString($0.trimmingCharacters(in: .whitespacesAndNewlines), comment: "User-defined equalizer preset") }.filter { !$0.isEmpty }
                                presetNames = names.isEmpty ? [
                                    NSLocalizedString("Preset 1", comment: "Equalizer preset 1"),
                                    NSLocalizedString("Preset 2", comment: "Equalizer preset 2"),
                                    NSLocalizedString("Preset 3", comment: "Equalizer preset 3"),
                                    NSLocalizedString("Preset 4", comment: "Equalizer preset 4")
                                ] : names
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
        menu.addItem(withTitle: NSLocalizedString("Settings...", comment: "Settings menu item"), action: #selector(openSettings), keyEquivalent: "s")
        menu.addItem(withTitle: NSLocalizedString("Quit", comment: "Quit menu item"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
    
    func showLowBatteryNotification(level: Int) {
        let content = UNMutableNotificationContent()
        content.title = "HeadsetControl-MacOSTray"
        content.body = String(format: NSLocalizedString("Low battery notification message", comment: "Low battery notification message"), level)
        content.sound = UNNotificationSound.default
        // App icon is shown by default in notification banner
        let request = UNNotificationRequest(identifier: "lowBatteryNotification", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // UNUserNotificationCenterDelegate: Show notifications when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge, .list])
    }
}
