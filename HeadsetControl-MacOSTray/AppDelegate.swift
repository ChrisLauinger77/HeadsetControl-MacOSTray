import Cocoa
import UserNotifications

@MainActor class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
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
    private let headsetController: HeadsetController
    private var stopping = false
    private var lastRequestedProfile: Int?

    override init() {
        headsetController = HeadsetController(provider: HeadsetControlService(), executor: HeadsetIOWorker.shared)
        super.init()
        bindHeadsetController()
    }

    init(headsetController: HeadsetController) {
        self.headsetController = headsetController
        super.init()
        bindHeadsetController()
    }

    private func bindHeadsetController() {
        headsetController.onDevices = { [weak self] devices in
            self?.applyDevices(devices.map(\.menuDictionary))
        }
    }

    private func runControlAction(_ sender: NSMenuItem, command: (Int) -> HeadsetCommand) {
        guard !stopping, let action = sender.representedObject as? HeadsetMenuAction,
              let target = action.target else { return }
        headsetController.perform(command(action.value), on: target,
                                  testProfile: UserDefaults.standard.integer(forKey: "testMode"))
    }

    @objc func setEqualizerPreset(_ sender: NSMenuItem) {
        runControlAction(sender) { .equalizerPreset($0) }
    }

    @objc func setRotateToMute(_ sender: NSMenuItem) {
        runControlAction(sender) { .rotateToMute($0 != 0) }
    }

    @objc func setVoicePrompts(_ sender: NSMenuItem) {
        runControlAction(sender) { .voicePrompts($0 != 0) }
    }

    @objc func setInactiveTime(_ sender: NSMenuItem) {
        runControlAction(sender) { .inactiveTime($0) }
    }

    @objc func setLights(_ sender: NSMenuItem) {
        runControlAction(sender) { .lights($0 != 0) }
    }

    @objc func setSidetoneLevel(_ sender: NSMenuItem) {
        runControlAction(sender) { .sidetone($0) }
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

    var lowBatteryThreshold: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "lowBatteryThreshold")
            return value == 0 ? 25 : min(max(value, 1), 30)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 1), 30), forKey: "lowBatteryThreshold")
        }
    }

    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?

    var statusUpdateTimer: Timer?
    var latestDevices: [[String: Any]]? = nil
    var lowBatteryNotificationShown = false
    private var activeTimerInterval: Int?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeApplicationAppearance()

        // Request notification authorization and set delegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            // Optionally handle granted/error
        }
        UNUserNotificationCenter.current().delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let sfImage = NSImage(systemSymbolName: "headset", accessibilityDescription: NSLocalizedString("Headset", comment: "Headset symbol accessibility description")) {
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

        // Observe defaults changes so updateInterval takes effect immediately
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserDefaultsChanged(_:)),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    private func observeApplicationAppearance() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateApplicationIcon()
            }
        }
    }

    private func updateApplicationIcon() {
        guard !stopping else { return }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        if let icon = AppIconProvider.image(isDark: isDark) {
            NSApp.applicationIconImage = icon
        }
    }

    func startStatusUpdateTimer() {
        guard !stopping else { return }
        statusUpdateTimer?.invalidate()

        let interval = updateInterval
        activeTimerInterval = interval

        statusUpdateTimer = Timer.scheduledTimer(withTimeInterval: Double(interval), repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
    }

    // Notifications may be posted from any thread. Read defaults and touch
    // AppKit/coordinator state only after entering the main actor.
    @objc nonisolated func handleRefreshNotification() {
        DispatchQueue.main.async { [weak self] in self?.updateStatusItem() }
    }

    @objc nonisolated func handleUserDefaultsChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopping else { return }
            if self.updateInterval != self.activeTimerInterval { self.startStatusUpdateTimer() }
            if UserDefaults.standard.integer(forKey: "testMode") != self.lastRequestedProfile {
                self.updateStatusItem()
            }
        }
    }

    func updateStatusItem() {
        guard !stopping else { return }
        let profile = UserDefaults.standard.integer(forKey: "testMode")
        if profile != lastRequestedProfile {
            latestDevices = []
            statusItem?.button?.title = ""
        }
        lastRequestedProfile = profile
        headsetController.refresh(testProfile: profile)
    }

    private func applyDevices(_ devicesResult: [[String: Any]]) {
        guard !stopping else { return }
        // A defaults notification can still be queued behind this result.
        guard UserDefaults.standard.integer(forKey: "testMode") == lastRequestedProfile else {
            updateStatusItem()
            return
        }
        var batteryLevelText: String? = nil
        if let device = devicesResult.first,
           let battery = device["battery"] as? [String: Any] {
            batteryLevelText = batteryChargeText(from: battery)
            let status = battery["status"] as? String ?? ""
            if let level = battery["level"] as? Int {
                let notifyOnLowBattery = UserDefaults.standard.object(forKey: "notifyOnLowBattery") as? Bool ?? true
                let lowBatteryThreshold = self.lowBatteryThreshold
                if notifyOnLowBattery && status == "BATTERY_AVAILABLE" && level <= lowBatteryThreshold && !lowBatteryNotificationShown {
                    showLowBatteryNotification(level: level)
                    lowBatteryNotificationShown = true
                }
                if status == "BATTERY_AVAILABLE" && level > lowBatteryThreshold {
                    lowBatteryNotificationShown = false
                }
            }
        }
        statusItem?.button?.title = batteryLevelText.map { " " + $0 } ?? ""
        latestDevices = devicesResult
    }

    // Never join the HID thread or take a lock around native work on the main
    // actor. AppKit defers process exit until handles and HID have been closed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stop {
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        stop()
    }

    func stop(completion: @escaping () -> Void = {}) {
        if !stopping {
            stopping = true
            statusUpdateTimer?.invalidate()
            statusUpdateTimer = nil
            NotificationCenter.default.removeObserver(self)
            appearanceObservation?.invalidate()
            appearanceObservation = nil
            statusMenu?.delegate = nil
            statusItem?.menu = nil
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            statusMenu = nil
            latestDevices = nil
        }
        headsetController.stop(completion: completion)
    }

    private func batteryChargeText(from battery: [String: Any]) -> String? {
        let status = battery["status"] as? String ?? ""
        let isCharging = status == "BATTERY_CHARGING"
        let prefix = isCharging ? "⚡︎ " : ""

        if let level = battery["level"] as? Int, level >= 0 {
            return prefix + "\(level)%"
        }

        return isCharging ? "⚡︎" : nil
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
            return " (\(NSLocalizedString("<1h", comment: "Battery time less than one hour")))"
        }
        let hours = mins / 60 // floor division as requested
        let hoursText = String(format: NSLocalizedString("%dh", comment: "Battery time in whole hours"), hours)
        return " (\(hoursText))"
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
            let controlTarget = device["control_target"] as? HeadsetTarget
            let deviceName = device["device"] as? String ?? NSLocalizedString("Unknown Device", comment: "Unknown device fallback")
            let vendor = device["vendor"] as? String ?? NSLocalizedString("Unknown Vendor", comment: "Unknown vendor fallback")
            let product = device["product"] as? String ?? NSLocalizedString("Unknown Product", comment: "Unknown product fallback")
            menu.addItem(withTitle: String(format: "%@: %@", NSLocalizedString("Device", comment: "Device label"), deviceName), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: String(format: "%@: %@", NSLocalizedString("Vendor", comment: "Vendor label"), vendor), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: String(format: "%@: %@", NSLocalizedString("Product", comment: "Product label"), product), action: nil, keyEquivalent: "")
            if let battery = device["battery"] as? [String: Any], let batteryText = batteryChargeText(from: battery) {
                // Append time-to-empty in hours (submenu only) when available. Use floor rounding and "h" suffix; show "<1h" for under 60 minutes.
                let suffix = formatTimeToEmpty(minutesAny: battery["time_to_empty_min"])
                let title = String(format: "%@: %@%@", NSLocalizedString("Battery", comment: "Battery label"), batteryText, suffix ?? "")
                menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            }
            if let chatmix = device["chatmix"] {
                menu.addItem(withTitle: String(format: "%@: %@", NSLocalizedString("Chatmix", comment: "Chatmix label"), String(describing: chatmix)), action: nil, keyEquivalent: "")
            }
            // Add menu items for selected capabilities
            if let capabilities = device["capabilities"] as? [String] {
                if controlTarget == nil && !capabilities.isEmpty {
                    menu.addItem(withTitle: NSLocalizedString("Controls unavailable: device connection is not unique", comment: "Cannot safely select a USB attachment"), action: nil, keyEquivalent: "")
                }
                let capabilityMap: [(String, String)] = [
                    ("CAP_SIDETONE", NSLocalizedString("Sidetone", comment: "Sidetone capability")),
                    ("CAP_LIGHTS", NSLocalizedString("Lights", comment: "Lights capability")),
                    ("CAP_INACTIVE_TIME", NSLocalizedString("Inactive Time", comment: "Inactive Time capability")),
                    ("CAP_VOICE_PROMPTS", NSLocalizedString("Voice Prompts", comment: "Voice Prompts capability")),
                    ("CAP_ROTATE_TO_MUTE", NSLocalizedString("Rotate to Mute", comment: "Rotate to Mute capability")),
                    ("CAP_EQUALIZER_PRESET", NSLocalizedString("Equalizer Preset", comment: "Equalizer Preset capability"))
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
                                item.representedObject = HeadsetMenuAction(target: controlTarget, value: levelValue)
                                if controlTarget == nil { item.action = nil }
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
                                item.representedObject = HeadsetMenuAction(target: controlTarget, value: optionValue)
                                if controlTarget == nil { item.action = nil }
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
                                item.representedObject = HeadsetMenuAction(target: controlTarget, value: optionValue)
                                if controlTarget == nil { item.action = nil }
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
                                item.representedObject = HeadsetMenuAction(target: controlTarget, value: optionValue)
                                if controlTarget == nil { item.action = nil }
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
                                item.representedObject = HeadsetMenuAction(target: controlTarget, value: optionValue)
                                if controlTarget == nil { item.action = nil }
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
                                item.representedObject = HeadsetMenuAction(target: controlTarget, value: idx)
                                if controlTarget == nil { item.action = nil }
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
        guard let settingsItem = NSApp.mainMenu?.items.first?.submenu?.items.first(where: {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
        }), let action = settingsItem.action else { return }

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(action, to: settingsItem.target, from: settingsItem)
        }
    }

    func showLowBatteryNotification(level: Int) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("HeadsetControl-MacOSTray", comment: "App title")
        content.body = String(format: NSLocalizedString("Low battery notification message", comment: "Low battery notification message"), level)
        content.sound = UNNotificationSound.default
        // App icon is shown by default in notification banner
        let request = UNNotificationRequest(identifier: "lowBatteryNotification", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // UNUserNotificationCenterDelegate: Show notifications when app is in foreground
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge, .list])
    }
}
