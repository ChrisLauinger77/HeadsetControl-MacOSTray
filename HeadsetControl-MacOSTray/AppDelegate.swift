import Cocoa
import UserNotifications

@MainActor class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    // Sidetone level values from UserDefaults
    var sidetoneLevelsFromSettings: [(String, Int)] {
        let off = AppDefaults.validatedSidetone(AppDefaults.standard.object(forKey: "sidetoneOff"), fallback: AppDefaults.sidetoneValues[0])
        let low = AppDefaults.validatedSidetone(AppDefaults.standard.object(forKey: "sidetoneLow"), fallback: AppDefaults.sidetoneValues[1])
        let mid = AppDefaults.validatedSidetone(AppDefaults.standard.object(forKey: "sidetoneMid"), fallback: AppDefaults.sidetoneValues[2])
        let high = AppDefaults.validatedSidetone(AppDefaults.standard.object(forKey: "sidetoneHigh"), fallback: AppDefaults.sidetoneValues[3])
        let max = AppDefaults.validatedSidetone(AppDefaults.standard.object(forKey: "sidetoneMax"), fallback: AppDefaults.sidetoneValues[4])
        return [
            (NSLocalizedString("Off", comment: "Sidetone level Off"), off),
            (NSLocalizedString("Low", comment: "Sidetone level Low"), low),
            (NSLocalizedString("Medium", comment: "Sidetone level Medium"), mid),
            (NSLocalizedString("High", comment: "Sidetone level High"), high),
            (NSLocalizedString("Maximum", comment: "Sidetone level Maximum"), max)
        ]
    }
    private let headsetController: HeadsetController
    private let lifecycleObserver: HeadsetLifecycleObserving
    private weak var trackingMenu: NSMenu?
    private var notificationCenter: UNUserNotificationCenter?
    private var stopping = false
    private var lastRequestedProfile: Int?
    private var lastNotificationEnabled: Bool?
    private var lastNotificationThreshold: Int?
    private let lowBatteryNotifications: LowBatteryNotifications
    private var statusBatteryText: String?
    // Last title applied to AppKit, also observable in tests without a live status item.
    private(set) var statusTitle = ""
    private var telemetryFailures: [HeadsetFailure] = []
    private(set) var refreshFailure: HeadsetFailure?
    private(set) var commandFailure: String?
    // A nil target represents the app-wide startup authorization request.
    private var notificationIssue: (target: HeadsetTarget?, failure: NotificationFailure)?
    var notificationFailure: NotificationFailure? { notificationIssue?.failure }

    override init() {
        _ = AppDefaults.standard
        lowBatteryNotifications = LowBatteryNotifications(delivery: SystemLowBatteryNotificationDelivery())
        headsetController = HeadsetController(provider: HeadsetControlService(), executor: HeadsetIOWorker.shared)
        lifecycleObserver = HeadsetLifecycleObserver()
        super.init()
        bindHeadsetController()
    }

    init(headsetController: HeadsetController, notificationDelivery: LowBatteryNotificationDelivering? = nil,
         lifecycleObserver: HeadsetLifecycleObserving? = nil) {
        _ = AppDefaults.standard
        lowBatteryNotifications = LowBatteryNotifications(delivery: notificationDelivery ?? SystemLowBatteryNotificationDelivery())
        self.headsetController = headsetController
        self.lifecycleObserver = lifecycleObserver ?? HeadsetLifecycleObserver()
        super.init()
        bindHeadsetController()
    }

    private func bindHeadsetController() {
        headsetController.updateRefreshInterval(updateInterval)
        headsetController.onRefresh = { [weak self] result in self?.applyRefresh(result) }
        headsetController.onSnapshotInvalidated = { [weak self] in
            guard let self, !self.stopping else { return }
            self.lowBatteryNotifications.suspend()
            self.updateStatusPresentation()
        }
        lowBatteryNotifications.isStillAllowed = { [weak self] notice in
            guard let self, !self.stopping else { return false }
            return self.headsetController.snapshotState == .fresh
                && AppDefaults.standard.bool(forKey: "notifyOnLowBattery") && notice.level <= self.lowBatteryThreshold
                && notice.target.accepts(testProfile: self.currentTestProfile)
        }
        lowBatteryNotifications.onFailure = { [weak self] target, error in
            self?.notificationIssue = (target, error)
            self?.updateStatusPresentation()
        }
        lowBatteryNotifications.onSuccess = { [weak self] target in
            guard let self, let issue = self.notificationIssue,
                  issue.target == nil || issue.target == target else { return }
            self.notificationIssue = nil
            self.updateStatusPresentation()
        }
    }

    private func runControlAction(_ sender: NSMenuItem, command: (Int) -> HeadsetCommand) {
        guard !stopping, let action = sender.representedObject as? HeadsetMenuAction,
              let target = action.target else { return }
        headsetController.perform(command(action.value), on: target,
                                  testProfile: currentTestProfile) { [weak self] result in
            guard let self, !self.stopping else { return }
            switch result {
            case .success: self.commandFailure = nil
            case .failure(let error):
                guard !error.isCancelled else { return }
                self.commandFailure = action.deviceName.isEmpty ? error.message : "\(action.deviceName): \(error.message)"
            }
            self.updateStatusPresentation()
        }
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

    private var currentTestProfile: Int {
        AppDefaults.validatedTestProfile(AppDefaults.standard.object(forKey: "testMode"))
    }

    var updateInterval: Int {
        get { AppDefaults.validatedUpdateInterval(AppDefaults.standard.object(forKey: "updateInterval")) }
        set { AppDefaults.standard.set(AppDefaults.validatedUpdateInterval(newValue), forKey: "updateInterval") }
    }

    var lowBatteryThreshold: Int {
        get { AppDefaults.validatedLowBatteryThreshold(AppDefaults.standard.object(forKey: "lowBatteryThreshold")) }
        set { AppDefaults.standard.set(AppDefaults.validatedLowBatteryThreshold(newValue), forKey: "lowBatteryThreshold") }
    }

    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?

    var statusUpdateTimer: Timer?
    var latestDevices: [[String: Any]]? = nil
    private var activeTimerInterval: Int?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeApplicationAppearance()
        startLifecycleObservation()

        // Request notification authorization and set delegate
        SystemLowBatteryNotificationDelivery().authorize { [weak self] result in
            guard let self, !self.stopping else { return }
            if case .failure(let error) = result {
                self.notificationIssue = (nil, error)
                self.updateStatusPresentation()
            }
        }
        notificationCenter = UNUserNotificationCenter.current()
        notificationCenter?.delegate = self

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

        // Observe defaults changes so updateInterval takes effect immediately
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserDefaultsChanged(_:)),
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    func startLifecycleObservation() {
        guard !stopping else { return }
        lifecycleObserver.start { [weak self] event in
            guard let self, !self.stopping else { return }
            switch event {
            case .willSleep: self.headsetController.invalidateSnapshot()
            case .resume: self.headsetController.recover(testProfile: self.currentTestProfile)
            case .usbChanged:
                // Physical USB events must not create test-profile work.
                if self.currentTestProfile == 0 { self.headsetController.recover(testProfile: 0) }
            }
        }
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

        let timer = Timer(timeInterval: Double(interval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }
        timer.tolerance = min(30, Double(interval) * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        statusUpdateTimer = timer
        headsetController.updateRefreshInterval(interval)
        updateStatusPresentation() // An increased interval may restore age-expired cached data.
    }

    // Notifications may be posted from any thread. Read defaults and touch
    // AppKit/coordinator state only after entering the main actor.
    @objc nonisolated func handleRefreshNotification() {
        HeadsetMainRunLoop.perform { [weak self] in self?.updateStatusItem() }
    }

    @objc nonisolated func handleUserDefaultsChanged(_ notification: Notification) {
        HeadsetMainRunLoop.perform { [weak self] in
            guard let self, !self.stopping else { return }
            AppDefaults.validate(in: AppDefaults.standard)
            if self.updateInterval != self.activeTimerInterval { self.startStatusUpdateTimer() }
            if self.currentTestProfile != self.lastRequestedProfile
                || AppDefaults.standard.bool(forKey: "notifyOnLowBattery") != self.lastNotificationEnabled
                || self.lowBatteryThreshold != self.lastNotificationThreshold {
                self.lowBatteryNotifications.suspend()
                self.updateStatusItem()
            }
        }
    }

    func updateStatusItem() {
        guard !stopping else { return }
        let profile = currentTestProfile
        if profile != lastRequestedProfile {
            latestDevices = []
            statusBatteryText = nil
            telemetryFailures = []
            refreshFailure = nil
            commandFailure = nil
            notificationIssue = nil
            lowBatteryNotifications.suspend()
        }
        lastRequestedProfile = profile
        lastNotificationEnabled = AppDefaults.standard.bool(forKey: "notifyOnLowBattery")
        lastNotificationThreshold = lowBatteryThreshold
        updateStatusPresentation() // Preference feedback must not wait for HID.
        headsetController.refresh(testProfile: profile)
    }

    private func applyRefresh(_ result: Result<[HeadsetDevice], HeadsetFailure>) {
        guard !stopping else { return }
        // A defaults notification can still be queued behind this result.
        guard currentTestProfile == lastRequestedProfile else { updateStatusItem(); return }
        switch result {
        case .failure(let error):
            refreshFailure = error
            // Preserve useful cached devices, explicitly labeled as stale.
            latestDevices = headsetController.snapshot.devices?.map(\.menuDictionary)
            lowBatteryNotifications.suspend()
        case .success(let devices):
            refreshFailure = nil
            latestDevices = devices.map(\.menuDictionary)
            telemetryFailures = devices.flatMap(\.failures)
            if let first = devices.first, case .success(let battery) = first.battery {
                statusBatteryText = battery.chargeText
            } else { statusBatteryText = nil }
            if headsetController.snapshotState == .fresh {
                lowBatteryNotifications.update(devices: devices, enabled: AppDefaults.standard.bool(forKey: "notifyOnLowBattery"),
                                               threshold: lowBatteryThreshold, testProfile: currentTestProfile)
            } else { lowBatteryNotifications.suspend() }
        }
        updateStatusPresentation()
    }

    private var feedbackMessages: [String] {
        [refreshFailure?.message, commandFailure, notificationFailure?.message].compactMap { $0 }
    }

    private func updateStatusPresentation() {
        guard !stopping else { return }
        // Also reject failures delivered before the queued defaults observer.
        if !AppDefaults.standard.bool(forKey: "notifyOnLowBattery") { notificationIssue = nil }
        let messages = feedbackMessages + telemetryFailures.map(\.message) + snapshotMessages
        let batteryText = headsetController.snapshotState == .fresh ? statusBatteryText : nil
        statusTitle = (batteryText.map { " " + $0 } ?? "") + (messages.isEmpty ? "" : " ⚠︎")
        statusItem?.button?.title = statusTitle
        statusItem?.button?.toolTip = messages.isEmpty ? nil : messages.joined(separator: "\n")
        if let trackingMenu { rebuildMenu(trackingMenu) }
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
            lowBatteryNotifications.stop()
            lifecycleObserver.stop()
            statusUpdateTimer?.invalidate()
            statusUpdateTimer = nil
            NotificationCenter.default.removeObserver(self)
            appearanceObservation?.invalidate()
            appearanceObservation = nil
            trackingMenu?.cancelTracking()
            trackingMenu = nil
            statusMenu?.delegate = nil
            statusItem?.menu = nil
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            statusTitle = ""
            statusMenu = nil
            latestDevices = nil
            if notificationCenter?.delegate === self { notificationCenter?.delegate = nil }
            notificationCenter = nil
        }
        headsetController.stop(completion: completion)
    }

    private func formatTimeToEmpty(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes < 60 { return " (\(NSLocalizedString("<1h", comment: "Battery time less than one hour")))" }
        return " (" + String(format: NSLocalizedString("%dh", comment: "Battery time in whole hours"), minutes / 60) + ")"
    }

    private var inactiveTimeMinutesFromSettings: [Int] {
        AppDefaults.parseInactiveTimeOptions(AppDefaults.standard.string(forKey: "inactiveTimeOptions") ?? AppDefaults.inactiveTimeOptionsRaw)
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

    private var snapshotMessages: [String] {
        let state = headsetController.snapshotState
        if state == .unobserved { return [NSLocalizedString("Checking devices…", comment: "Initial asynchronous discovery")] }
        guard state == .stale || (state == .failed && headsetController.snapshot.observedAt != nil) else { return [] }
        var messages = [NSLocalizedString("Device data may be out of date", comment: "Cached snapshot warning")]
        if let date = headsetController.snapshot.observedAt {
            let time = DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .medium)
            messages.append(String(format: NSLocalizedString("Last checked: %@", comment: "Time of cached device observation"), time))
        }
        return messages
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !stopping else { menu.removeAllItems(); return }
        if let lastRequestedProfile, lastRequestedProfile != currentTestProfile { updateStatusItem() }
        else { headsetController.refreshIfNeeded(testProfile: currentTestProfile) }
        rebuildMenu(menu)
    }

    func menuWillOpen(_ menu: NSMenu) { if !stopping { trackingMenu = menu } }
    func menuDidClose(_ menu: NSMenu) { if trackingMenu === menu { trackingMenu = nil } }

    // Rendering is separate from refresh requests: a result may update an open
    // menu, but must never recursively schedule another native transaction.
    func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !stopping else { return }
        for message in snapshotMessages { menu.addItem(withTitle: message, action: nil, keyEquivalent: "") }
        for message in feedbackMessages { menu.addItem(withTitle: message, action: nil, keyEquivalent: "") }
        if refreshFailure != nil {
            let retry = menu.addItem(withTitle: NSLocalizedString("Retry refresh", comment: "Retry discovery after failure"), action: #selector(handleRefreshNotification), keyEquivalent: "")
            retry.target = self
        }
        guard let devices = latestDevices, !devices.isEmpty else {
            if headsetController.snapshotState == .empty {
                menu.addItem(withTitle: NSLocalizedString("No devices found", comment: "No devices found message"), action: nil, keyEquivalent: "")
            } else if headsetController.snapshot.observedAt != nil && refreshFailure == nil {
                menu.addItem(withTitle: NSLocalizedString("No devices in last check", comment: "Empty cached discovery"), action: nil, keyEquivalent: "")
            }
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
            if let battery = device["battery"] as? Result<HeadsetBattery, HeadsetFailure> {
                switch battery {
                case .success(let value):
                    let suffix = value.percentage != nil ? formatTimeToEmpty(minutes: value.timeToEmpty) ?? "" : ""
                    menu.addItem(withTitle: "\(NSLocalizedString("Battery", comment: "Battery label")): \(value.chargeText ?? value.statusText)\(suffix)", action: nil, keyEquivalent: "")
                case .failure(let error): menu.addItem(withTitle: error.message, action: nil, keyEquivalent: "")
                }
            }
            if let chatmix = device["chatmix"] as? Result<Int, HeadsetFailure> {
                switch chatmix {
                case .success(let level): menu.addItem(withTitle: "\(NSLocalizedString("Chatmix", comment: "Chatmix label")): \(level)", action: nil, keyEquivalent: "")
                case .failure(let error): menu.addItem(withTitle: error.message, action: nil, keyEquivalent: "")
                }
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
                                item.representedObject = HeadsetMenuAction(target: controlTarget, value: levelValue, deviceName: deviceName)
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
                                item.representedObject = HeadsetMenuAction(target: controlTarget, value: optionValue, deviceName: deviceName)
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
                                item.representedObject = HeadsetMenuAction(target: controlTarget, value: optionValue, deviceName: deviceName)
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
                                item.representedObject = HeadsetMenuAction(target: controlTarget, value: optionValue, deviceName: deviceName)
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
                                item.representedObject = HeadsetMenuAction(target: controlTarget, value: optionValue, deviceName: deviceName)
                                if controlTarget == nil { item.action = nil }
                                inactiveTimeMenu.addItem(item)
                            }
                            let inactiveTimeMenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                            menu.addItem(inactiveTimeMenuItem)
                            menu.setSubmenu(inactiveTimeMenu, for: inactiveTimeMenuItem)
                        case "CAP_EQUALIZER_PRESET":
                            let eqPresetMenu = NSMenu(title: NSLocalizedString("Equalizer Preset", comment: "Equalizer Preset capability"))
                            let metadata = device["equalizerPresets"] as? Result<[HeadsetEqualizerPreset], HeadsetFailure>
                            if case .success(let presets) = metadata, !presets.isEmpty {
                                let fallback = AppDefaults.standard.string(forKey: "equalizerPresets") ?? AppDefaults.equalizerPresets
                                for preset in presets {
                                    let name = preset.name ?? AppDefaults.presetName(index: preset.index, fallbackNames: fallback)
                                    let item = NSMenuItem(title: name, action: #selector(setEqualizerPreset(_:)), keyEquivalent: "")
                                    item.target = self
                                    item.representedObject = HeadsetMenuAction(target: controlTarget, value: preset.index, deviceName: deviceName)
                                    if controlTarget == nil { item.action = nil }
                                    eqPresetMenu.addItem(item)
                                }
                            } else {
                                let message: String
                                if case .failure(let error) = metadata { message = error.message }
                                else { message = NSLocalizedString("Preset metadata unavailable", comment: "No supported preset indices available") }
                                eqPresetMenu.addItem(withTitle: message, action: nil, keyEquivalent: "")
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
        guard !stopping, let settingsItem = NSApp.mainMenu?.items.first?.submenu?.items.first(where: {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
        }), let action = settingsItem.action else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopping else { return }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(action, to: settingsItem.target, from: settingsItem)
        }
    }

    // UNUserNotificationCenterDelegate: Show notifications when app is in foreground
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { [weak self] in
            completionHandler(self?.stopping == false ? [.banner, .sound, .badge, .list] : [])
        }
    }
}
