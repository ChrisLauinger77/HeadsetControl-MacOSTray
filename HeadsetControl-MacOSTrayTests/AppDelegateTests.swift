import AppKit
import XCTest
@testable import HeadsetControl_MacOSTray

@MainActor class AppDelegateTests: XCTestCase {
    private func microphoneDevice(muted: Result<Bool, HeadsetFailure>?, attached: Result<Bool, HeadsetFailure>?) -> HeadsetDevice {
        HeadsetDevice(usbID: .testDevice, name: "Headset", vendor: "Vendor", product: "Product", capabilities: ["CAP_LIGHTS"],
                      battery: .success(.init(level: 42, status: .available)), microphoneMuted: muted, microphoneAttached: attached,
                      target: .test(profile: 7))
    }

    func testMicrophoneRowsShowBothStatesAndOmitUnsupportedReadings() async {
        let delegate = AppDelegate()
        for (muted, attached) in [(false, true), (true, false)] {
            let device = microphoneDevice(muted: .success(muted), attached: .success(attached))
            delegate.latestDevices = [device.menuDictionary]
            let menu = NSMenu()
            delegate.rebuildMenu(menu)
            XCTAssertTrue(menu.items.contains { $0.title == String(format: localized("Microphone: %@"), localized(muted ? "Muted" : "On")) })
            XCTAssertTrue(menu.items.contains { $0.title == String(format: localized("Boom mic: %@"), localized(attached ? "Attached" : "Detached")) })
        }
        delegate.latestDevices = [microphoneDevice(muted: nil, attached: nil).menuDictionary]
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix(localized("Microphone") + ":") || $0.title.hasPrefix(localized("Boom mic") + ":") })
    }

    func testMicrophoneTimeoutsKeepBatteryAndOtherControlsVisible() async {
        let muteError = HeadsetFailure(operation: .microphone, kind: .native(-4))
        let attachmentError = HeadsetFailure(operation: .boomMicrophone, kind: .native(-3))
        let device = microphoneDevice(muted: .failure(muteError), attached: .failure(attachmentError))
        let delegate = AppDelegate()
        delegate.latestDevices = [device.menuDictionary]
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        XCTAssertTrue(menu.items.contains { $0.title == muteError.message })
        XCTAssertTrue(menu.items.contains { $0.title == attachmentError.message })
        XCTAssertTrue(menu.items.contains { $0.title == "\(localized("Battery")): 42%" })
        XCTAssertNotNil(menu.items.first { $0.title == localized("Lights") }?.submenu)
        XCTAssertEqual(device.failures, [muteError, attachmentError])
    }

    func testMuteIconPreferenceAndFreshnessUseCachedReadingsWithoutMenuQueries() async {
        UserDefaults.standard.set(7, forKey: "testMode")
        UserDefaults.standard.set(true, forKey: "showMicrophoneMuteIcon")
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let controller = HeadsetController(provider: provider, executor: executor)
        let delegate = AppDelegate(headsetController: controller)
        provider.devices = [microphoneDevice(muted: nil, attached: nil), microphoneDevice(muted: .success(true), attached: .success(true))]
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        XCTAssertEqual(delegate.statusIcon, .microphoneMuted)
        let menu = NSMenu()
        for _ in 0..<3 { delegate.menuNeedsUpdate(menu) }
        XCTAssertEqual(provider.profiles, [7])
        XCTAssertTrue(executor.jobs.isEmpty)
        UserDefaults.standard.set(false, forKey: "showMicrophoneMuteIcon")
        delegate.handleUserDefaultsChanged(Notification(name: UserDefaults.didChangeNotification))
        await drainResults()
        XCTAssertEqual(delegate.statusIcon, .headset)
        XCTAssertTrue(executor.jobs.isEmpty)
        UserDefaults.standard.set(true, forKey: "showMicrophoneMuteIcon")
        delegate.handleUserDefaultsChanged(Notification(name: UserDefaults.didChangeNotification))
        await drainResults()
        XCTAssertEqual(delegate.statusIcon, .microphoneMuted)
        XCTAssertTrue(executor.jobs.isEmpty)
        controller.invalidateSnapshot()
        XCTAssertEqual(delegate.statusIcon, .headset)
        provider.devices = []
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        XCTAssertEqual(delegate.statusIcon, .headset)
        delegate.stop()
        executor.finishStop()
        await drainResults()
    }

    func testNativeTestModeMicrophoneMenuShowsOnAndAttached() async throws {
        let service = HeadsetControlService()
        let result = await withCheckedContinuation { continuation in
            HeadsetIOWorker.shared.enqueue { continuation.resume(returning: service.fetchDevices(testProfile: 7)) }
        }
        let delegate = AppDelegate()
        delegate.latestDevices = [try XCTUnwrap(result.get().first).menuDictionary]
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        XCTAssertTrue(menu.items.contains { $0.title == String(format: localized("Microphone: %@"), localized("On")) })
        XCTAssertTrue(menu.items.contains { $0.title == String(format: localized("Boom mic: %@"), localized("Attached")) })
    }

    func testBluetoothCallVolumePresetsAppearAndDispatchWithoutReadback() async throws {
        UserDefaults.standard.set(-1, forKey: "bluetoothCallVolumeOff")
        UserDefaults.standard.set(43, forKey: "bluetoothCallVolumeMid")
        defer { AppDefaults.bluetoothCallVolumeKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        try await verifyWriteOnlyControl(.bluetoothCallVolume, title: "Bluetooth Call Volume", values: [25, 43, 75, 100],
                                        commands: [25, 43, 75, 100].map(HeadsetCommand.bluetoothCallVolume))
    }

    func testANCOffersAllModesWithoutReadback() async throws {
        try await verifyWriteOnlyControl(.anc, title: "Noise cancelling", values: [0, 1, 2],
                                        commands: [0, 1, 2].map(HeadsetCommand.anc))
    }

    func testLightsMenuOffersOnOffAndColorPresetsWithoutReadback() async throws {
        let colors = AppDefaults.lightColorValues
        try await verifyWriteOnlyControl(.lightColor, title: "Lights", values: [0, 1] + colors,
                                        commands: [.lights(false), .lights(true)] + colors.map { .lightColor(HeadsetLightColor(rgb: $0)) })
    }

    func testLightColorsFollowSettingsAndAppearWithoutLightsCapability() throws {
        UserDefaults.standard.set(0x123456, forKey: "lightColor2")
        UserDefaults.standard.set("invalid", forKey: "lightColor3")
        defer { AppDefaults.lightColorKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        let delegate = AppDelegate()
        let colorTitles = ["#FFFFFF", "#123456", "#00FF00", "#0000FF"]
        for (capabilities, titles) in [(["CAP_LIGHTS", "CAP_LIGHT_COLOR"], [localized("Off"), localized("On"), ""] + colorTitles),
                                       (["CAP_LIGHT_COLOR"], colorTitles)] {
            let device = HeadsetDevice(usbID: .testDevice, name: "Headset", vendor: "Vendor", product: "Product",
                                       capabilities: capabilities, target: .test(profile: 7))
            delegate.latestDevices = [device.menuDictionary]
            let menu = NSMenu()
            delegate.rebuildMenu(menu)
            let submenu = try XCTUnwrap(menu.items.first { $0.title == localized("Lights") }?.submenu)
            XCTAssertEqual(submenu.items.map(\.title), titles)
            XCTAssertEqual(submenu.items.filter(\.isSeparatorItem).count, capabilities.count - 1)
            for item in submenu.items.suffix(colorTitles.count) {
                XCTAssertNotNil(item.image)
                XCTAssertEqual(item.action, #selector(AppDelegate.setLightColor(_:)))
            }
        }
    }

    func testNativeANCMenuCommandsSucceedInTestMode() async throws {
        UserDefaults.standard.set(7, forKey: "testMode")
        let controller = HeadsetController(provider: HeadsetControlService(), executor: HeadsetIOWorker.shared)
        let delegate = AppDelegate(headsetController: controller, notificationDelivery: RecordingNotificationDelivery())
        let refreshed = expectation(description: "native ANC device discovered")
        let originalRefresh = controller.onRefresh
        controller.onRefresh = { result in originalRefresh?(result); refreshed.fulfill() }
        delegate.updateStatusItem()
        await fulfillment(of: [refreshed], timeout: 5)
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        let submenu = try XCTUnwrap(menu.items.first { $0.title == localized("Noise cancelling") }?.submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["Off", "Noise cancelling", "Ambient sound"].map(localized))
        for item in submenu.items {
            _ = delegate.perform(try XCTUnwrap(item.action), with: item)
        }
        // A worker barrier followed by a main-run-loop barrier delivers all results.
        let writes = expectation(description: "native ANC menu writes finish")
        HeadsetIOWorker.shared.enqueue { writes.fulfill() }
        await fulfillment(of: [writes], timeout: 5)
        await drainResults()
        XCTAssertNil(delegate.commandFailure)
        delegate.rebuildMenu(menu)
        XCTAssertTrue(try XCTUnwrap(menu.items.first { $0.title == localized("Noise cancelling") }?.submenu).items.allSatisfy { $0.state == .off })
    }

    func testANCSettingsSelectOneSupportingTargetAndUseQueuedCommands() async throws {
        UserDefaults.standard.set(0, forKey: "testMode")
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let controller = HeadsetController(provider: provider, executor: executor)
        let delegate = AppDelegate(headsetController: controller)
        let startupTarget = HeadsetTarget.physical(.init(vendor: 3, product: 4), attachmentID: 22)
        let cycleTarget = HeadsetTarget.physical(.init(vendor: 5, product: 6), attachmentID: 33)
        func device(_ name: String, capabilities: [String], target: HeadsetTarget?) -> HeadsetDevice {
            HeadsetDevice(usbID: .init(vendor: 1, product: 2), name: name, vendor: "Vendor", product: "Product",
                          capabilities: capabilities, target: target)
        }
        provider.devices = [
            device("Unsupported", capabilities: [], target: startupTarget),
            device("Ambiguous", capabilities: ["CAP_ANC_STARTUP_MODE", "CAP_ANC_BUTTON_MODES"], target: nil),
            device("Old test mode", capabilities: ["CAP_ANC_STARTUP_MODE"], target: .test(profile: 7)),
            device("Startup", capabilities: ["CAP_ANC_STARTUP_MODE"], target: startupTarget),
            device("Cycle", capabilities: ["CAP_ANC_STARTUP_MODE", "CAP_ANC_BUTTON_MODES"], target: cycleTarget)
        ]
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        delegate.performANCSettingsCommand(.ancStartupMode(2))
        delegate.performANCSettingsCommand(.ancButtonModes([.anc, .ambient]))
        XCTAssertTrue(provider.commands.isEmpty)
        XCTAssertEqual(executor.jobs.count, 2)
        executor.runNext()
        executor.runNext()
        await drainResults()
        XCTAssertEqual(provider.commands.map { $0.0 }, [.ancStartupMode(2), .ancButtonModes([.anc, .ambient])])
        XCTAssertEqual(provider.commands.map { $0.1 }, [startupTarget, cycleTarget])
        XCTAssertEqual(provider.commands.map { $0.2 }, [0, 0])
        provider.commandResult = .failure(.init(operation: .command, kind: .native(-5)))
        delegate.performANCSettingsCommand(.ancStartupMode(1))
        executor.runNext()
        await drainResults()
        XCTAssertTrue(delegate.commandFailure?.contains("Startup:") == true)
        XCTAssertTrue(delegate.commandFailure?.contains("-5") == true)

        controller.invalidateSnapshot()
        delegate.performANCSettingsCommand(.ancStartupMode(0))
        XCTAssertTrue(executor.jobs.isEmpty)
        XCTAssertEqual(delegate.commandFailure, HeadsetFailure(operation: .command, kind: .targetUnavailable).message)
        delegate.stop()
        executor.finishStop()
        await drainResults()
    }

    func testANCSettingsRetrySavedSelectionsAfterReconnectStalenessAndNativeFailure() async {
        let store = AppDefaults.standard
        let savedStartup = store.object(forKey: "ancStartupMode")
        let savedCycle = store.object(forKey: "ancButtonModes")
        let savedProfile = store.object(forKey: "testMode")
        defer {
            store.set(savedStartup, forKey: "ancStartupMode")
            store.set(savedCycle, forKey: "ancButtonModes")
            store.set(savedProfile, forKey: "testMode")
        }
        store.set(7, forKey: "testMode")
        store.set(3, forKey: "ancStartupMode")
        store.set(HeadsetANCButtonModes.all.rawValue, forKey: "ancButtonModes")
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let controller = HeadsetController(provider: provider, executor: executor)
        let delegate = AppDelegate(headsetController: controller)
        delegate.updateStatusItem() // Successfully discover no connected headset.
        executor.runNext()
        await drainResults()
        let view = ANCSettingsView(onCommand: { delegate.performANCSettingsCommand($0) })
        view.startupModeBinding.wrappedValue = 1
        view.buttonModeBinding(.off).wrappedValue = false
        XCTAssertTrue(executor.jobs.isEmpty)
        XCTAssertNotNil(delegate.commandFailure)

        provider.devices = [HeadsetDevice(usbID: .testDevice, name: "Test", vendor: "Vendor", product: "Product",
                                         capabilities: ["CAP_ANC_STARTUP_MODE", "CAP_ANC_BUTTON_MODES"], target: .test(profile: 7))]
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        controller.invalidateSnapshot()
        view.applyStartupMode()
        view.applyButtonModes()
        XCTAssertTrue(executor.jobs.isEmpty)
        XCTAssertTrue(provider.commands.isEmpty)
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()

        // Reopening Settings preserves the unapplied values and permits retry.
        let reopened = ANCSettingsView(onCommand: { delegate.performANCSettingsCommand($0) })
        provider.commandResult = .failure(.init(operation: .command, kind: .native(-5)))
        reopened.applyStartupMode()
        reopened.applyButtonModes()
        executor.runNext()
        executor.runNext()
        await drainResults()
        XCTAssertTrue(delegate.commandFailure?.contains("-5") == true)
        provider.commandResult = .success(())
        reopened.applyStartupMode()
        reopened.applyButtonModes()
        executor.runNext()
        executor.runNext()
        await drainResults()
        XCTAssertNil(delegate.commandFailure)
        let intended: [HeadsetCommand] = [.ancStartupMode(1), .ancButtonModes([.anc, .ambient])]
        XCTAssertEqual(provider.commands.map { $0.0 }, intended + intended)
        XCTAssertEqual(provider.commands.map { $0.1 }, Array(repeating: .test(profile: 7), count: 4))
        XCTAssertEqual(store.integer(forKey: "ancStartupMode"), 1)
        XCTAssertEqual(store.integer(forKey: "ancButtonModes"), HeadsetANCButtonModes([.anc, .ambient]).rawValue)
        delegate.stop()
        executor.finishStop()
        await drainResults()
    }

    func testANCSettingsRejectMissingCapabilitiesProfileChangesAndShutdown() async {
        UserDefaults.standard.set(7, forKey: "testMode")
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let controller = HeadsetController(provider: provider, executor: executor)
        let delegate = AppDelegate(headsetController: controller)
        provider.devices = [microphoneDevice(muted: nil, attached: nil)]
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        delegate.performANCSettingsCommand(.ancStartupMode(1))
        delegate.performANCSettingsCommand(.ancButtonModes(.off))
        XCTAssertTrue(executor.jobs.isEmpty)
        provider.devices = [HeadsetDevice(usbID: .testDevice, name: "Test", vendor: "Vendor", product: "Product",
                                         capabilities: ["CAP_ANC_STARTUP_MODE", "CAP_ANC_BUTTON_MODES"], target: .test(profile: 7))]
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        UserDefaults.standard.set(0, forKey: "testMode")
        delegate.performANCSettingsCommand(.ancStartupMode(1))
        XCTAssertTrue(executor.jobs.isEmpty)
        delegate.stop()
        delegate.performANCSettingsCommand(.ancButtonModes(.all))
        XCTAssertTrue(executor.jobs.isEmpty)
        executor.finishStop()
        await drainResults()
    }

    func testBluetoothPowerOnOffersOnAndOffWithoutReadback() async throws {
        try await verifyWriteOnlyControl(.bluetoothWhenPoweredOn, title: "Bluetooth on at Power-On", values: [0, 1],
                                        commands: [.bluetoothWhenPoweredOn(false), .bluetoothWhenPoweredOn(true)])
    }

    func testMicMuteLedBrightnessOffersAllFourStepsWithoutReadback() async throws {
        try await verifyWriteOnlyControl(.microphoneMuteLedBrightness, title: "Mic Mute LED Brightness", values: [0, 1, 2, 3],
                                        commands: [0, 1, 2, 3].map(HeadsetCommand.microphoneMuteLedBrightness))
    }

    func testVolumeLimiterOffersOnAndOffWithoutReadback() async throws {
        try await verifyWriteOnlyControl(.volumeLimiter, title: "Volume Limiter", values: [0, 1], commands: [.volumeLimiter(false), .volumeLimiter(true)])
    }

    func testNoiseFilterOffersOffLowAndHighWithoutReadback() async throws {
        try await verifyWriteOnlyControl(.noiseFilter, title: "Microphone Noise Filter", values: [0, 1, 2],
                                        commands: [0, 1, 2].map(HeadsetCommand.noiseFilter))
    }

    private func verifyWriteOnlyControl(_ capability: HeadsetCapability, title: String, values: [Int], commands: [HeadsetCommand]) async throws {
        UserDefaults.standard.set(7, forKey: "testMode")
        let service = HeadsetControlService()
        let result = await withCheckedContinuation { continuation in
            HeadsetIOWorker.shared.enqueue { continuation.resume(returning: service.fetchDevices(testProfile: 7)) }
        }
        let device = try XCTUnwrap(result.get().first)
        XCTAssertTrue(device.capabilities.contains(capability.legacyCapabilityString))
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let delegate = AppDelegate(headsetController: HeadsetController(provider: provider, executor: executor))
        delegate.latestDevices = [device.menuDictionary]
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        let submenu = try XCTUnwrap(menu.items.first { $0.title == localized(title) }?.submenu)
        XCTAssertEqual(submenu.items.compactMap { ($0.representedObject as? HeadsetMenuAction)?.value }, values)
        for item in submenu.items where !item.isSeparatorItem {
            XCTAssertEqual(item.state, .off)
            XCTAssertEqual((item.representedObject as? HeadsetMenuAction)?.target, .test(profile: 7))
            _ = delegate.perform(try XCTUnwrap(item.action), with: item)
            executor.runNext()
            await drainResults()
        }
        XCTAssertEqual(provider.commands.map { $0.0 }, commands)
        provider.commandResult = .failure(.init(operation: .command, kind: .native(-5)))
        let item = try XCTUnwrap(submenu.items.first)
        _ = delegate.perform(try XCTUnwrap(item.action), with: item)
        executor.runNext()
        await drainResults()
        XCTAssertTrue(delegate.commandFailure?.contains("-5") == true)
        var ambiguous = device.menuDictionary
        ambiguous.removeValue(forKey: "control_target")
        delegate.latestDevices = [ambiguous]
        delegate.rebuildMenu(menu)
        XCTAssertTrue(try XCTUnwrap(menu.items.first { $0.title == localized(title) }?.submenu).items.allSatisfy { $0.action == nil })
        ambiguous["capabilities"] = [String]()
        delegate.latestDevices = [ambiguous]
        delegate.rebuildMenu(menu)
        XCTAssertFalse(menu.items.contains { $0.title == localized(title) })
    }

    func testMicrophoneVolumePresetsAppearAndDispatchWithoutReadback() async throws {
        UserDefaults.standard.set(-1, forKey: "microphoneVolumeOff")
        UserDefaults.standard.set(17, forKey: "microphoneVolumeLow")
        defer { AppDefaults.microphoneVolumeKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        try await verifyWriteOnlyControl(.microphoneVolume, title: "Microphone Volume", values: [17, 64, 96, 128],
                                        commands: [17, 64, 96, 128].map(HeadsetCommand.microphoneVolume))
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "updateInterval")
        UserDefaults.standard.removeObject(forKey: "lowBatteryThreshold")
        UserDefaults.standard.removeObject(forKey: "sidetoneOff")
        UserDefaults.standard.removeObject(forKey: "sidetoneLow")
        UserDefaults.standard.removeObject(forKey: "sidetoneMid")
        UserDefaults.standard.removeObject(forKey: "sidetoneHigh")
        UserDefaults.standard.removeObject(forKey: "sidetoneMax")
        UserDefaults.standard.removeObject(forKey: "inactiveTimeOptions")
        UserDefaults.standard.removeObject(forKey: "equalizerPresets")
        UserDefaults.standard.removeObject(forKey: "testMode")
        UserDefaults.standard.removeObject(forKey: "notifyOnLowBattery")
        UserDefaults.standard.removeObject(forKey: "showMicrophoneMuteIcon")
        super.tearDown()
    }

    func testDefaultUpdateInterval() async {
        let appDelegate = AppDelegate()
        // Default value should be 600 if not set
        UserDefaults.standard.removeObject(forKey: "updateInterval")
        XCTAssertEqual(appDelegate.updateInterval, 600)
    }

    func testDefaultLowBatteryThreshold() async {
        UserDefaults.standard.removeObject(forKey: "lowBatteryThreshold")
        let appDelegate = AppDelegate()
        XCTAssertEqual(appDelegate.lowBatteryThreshold, 25)
    }

    func testLowBatteryThresholdClampsToValidRange() async {
        let appDelegate = AppDelegate()

        appDelegate.lowBatteryThreshold = 99
        XCTAssertEqual(appDelegate.lowBatteryThreshold, 30)

        appDelegate.lowBatteryThreshold = -5
        XCTAssertEqual(appDelegate.lowBatteryThreshold, 1)
    }

    func testSidetoneLevelsComeFromUserDefaultsInMenuOrder() async {
        UserDefaults.standard.set(-1, forKey: "sidetoneOff")
        UserDefaults.standard.set(12, forKey: "sidetoneLow")
        UserDefaults.standard.set(34, forKey: "sidetoneMid")
        UserDefaults.standard.set(56, forKey: "sidetoneHigh")
        UserDefaults.standard.set(78, forKey: "sidetoneMax")

        let appDelegate = AppDelegate()
        let levels = appDelegate.sidetoneLevelsFromSettings

        XCTAssertEqual(levels.map { $0.0 }, [
            localized("Off"),
            localized("Low"),
            localized("Medium"),
            localized("High"),
            localized("Maximum")
        ])
        XCTAssertEqual(levels.map { $0.1 }, [-1, 12, 34, 56, 78])
    }

    func testNoDevicesMenuStillProvidesSettingsAndQuitActions() async {
        let executor = ManualHeadsetExecutor()
        let appDelegate = AppDelegate(headsetController: HeadsetController(provider: RecordingHeadsetProvider(), executor: executor))
        appDelegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        let menu = NSMenu()

        appDelegate.rebuildMenu(menu)

        XCTAssertEqual(menu.items.map { $0.title }, [
            localized("No devices found"),
            "",
            localized("Settings..."),
            localized("Quit")
        ])
        XCTAssertEqual(menu.items[2].action, #selector(AppDelegate.openSettings))
        XCTAssertEqual(menu.items[3].action, #selector(NSApplication.terminate(_:)))
    }

    func testMenuFiltersAndSortsInactiveTimeOptionsFromSettings() async throws {
        UserDefaults.standard.set("90, 15, 15, 999, abc, 1", forKey: "inactiveTimeOptions")
        let appDelegate = AppDelegate()
        appDelegate.latestDevices = [[
            "device": "Test Headset",
            "vendor": "Test Vendor",
            "product": "Test Product",
            "capabilities": ["CAP_INACTIVE_TIME"]
        ]]
        let menu = NSMenu()

        appDelegate.rebuildMenu(menu)

        let inactiveTimeItem = try XCTUnwrap(menu.items.first { $0.title == localized("Inactive Time") })
        let submenu = try XCTUnwrap(inactiveTimeItem.submenu)
        XCTAssertEqual(submenu.items.map { $0.title }, [
            localized("Off"),
            localized("1 Minute"),
            localized("15 Minutes"),
            localized("90 Minutes")
        ])
        XCTAssertEqual(submenu.items.map { ($0.representedObject as? HeadsetMenuAction)?.value }, [0, 1, 15, 90])
    }

    func testMenuUsesConfiguredEqualizerNamesOnlyForReportedIndicesWithoutNames() async throws {
        UserDefaults.standard.set("Game, Music, Voice", forKey: "equalizerPresets")
        let appDelegate = AppDelegate()
        appDelegate.latestDevices = [[
            "device": "Test Headset",
            "vendor": "Test Vendor",
            "product": "Test Product",
            "capabilities": ["CAP_EQUALIZER_PRESET"],
            "equalizerPresets": Result<[HeadsetEqualizerPreset], HeadsetFailure>.success((0..<3).map { .init(index: $0, name: nil) })
        ]]
        let menu = NSMenu()

        appDelegate.rebuildMenu(menu)

        let equalizerItem = try XCTUnwrap(menu.items.first { $0.title == localized("Equalizer Preset") })
        let submenu = try XCTUnwrap(equalizerItem.submenu)
        XCTAssertEqual(submenu.items.map { $0.title }, ["Game", "Music", "Voice"])
        XCTAssertEqual(submenu.items.map { ($0.representedObject as? HeadsetMenuAction)?.value }, [0, 1, 2])
    }

    func testMenuFormatsBatteryTimeToEmptyWithoutRoundingUp() async {
        let appDelegate = AppDelegate()
        appDelegate.latestDevices = [[
            "device": "Test Headset",
            "vendor": "Test Vendor",
            "product": "Test Product",
            "battery": Result<HeadsetBattery, HeadsetFailure>.success(.init(level: 44, status: .available, timeToEmpty: 119, timeToFull: 60)),
            "capabilities": []
        ]]
        let menu = NSMenu()

        appDelegate.rebuildMenu(menu)

        let hoursText = String(format: localized("%dh"), 1)
        XCTAssertTrue(menu.items.contains { $0.title == "\(localized("Battery")): 44% (\(hoursText))" })
    }

    func testMockProviderReturnsMenuCapabilitiesAndClampedBatteryLevel() async throws {
        let lowIndexProvider = MockHeadsetControlService(deviceIndex: 0)
        let highIndexProvider = MockHeadsetControlService(deviceIndex: 20)

        let lowBattery = try XCTUnwrap(lowIndexProvider.fetchDevices(testProfile: 7).successValue?.first?.battery?.successValue)
        let highBattery = try XCTUnwrap(highIndexProvider.fetchDevices(testProfile: 7).successValue?.first?.battery?.successValue)
        let capabilities = try XCTUnwrap(lowIndexProvider.fetchDevices(testProfile: 7).successValue?.first?.menuDictionary["capabilities"] as? [String])

        XCTAssertEqual(lowBattery.percentage, 5)
        XCTAssertEqual(highBattery.percentage, 95)
        XCTAssertEqual(capabilities, HeadsetCapability.menuCapabilities.map { $0.legacyCapabilityString })
    }

    func testKnownCapabilitiesExposeLegacyMenuStrings() async {
        XCTAssertEqual(HeadsetCapability.headsetVolume.legacyCapabilityString, "CAP_HEADSET_VOLUME")
        XCTAssertEqual(HeadsetCapability.anc.legacyCapabilityString, "CAP_ANC")
        XCTAssertEqual(HeadsetCapability.ancStartupMode.legacyCapabilityString, "CAP_ANC_STARTUP_MODE")
        XCTAssertEqual(HeadsetCapability.ancButtonModes.legacyCapabilityString, "CAP_ANC_BUTTON_MODES")
        XCTAssertEqual(HeadsetCapability.sidetone.legacyCapabilityString, "CAP_SIDETONE")
        XCTAssertEqual(HeadsetCapability.sidetoneStatus.legacyCapabilityString, "CAP_SIDETONE_STATUS")
        XCTAssertEqual(HeadsetCapability.lights.legacyCapabilityString, "CAP_LIGHTS")
        XCTAssertEqual(HeadsetCapability.lightColor.legacyCapabilityString, "CAP_LIGHT_COLOR")
        XCTAssertEqual(HeadsetCapability.inactiveTime.legacyCapabilityString, "CAP_INACTIVE_TIME")
        XCTAssertEqual(HeadsetCapability.voicePrompts.legacyCapabilityString, "CAP_VOICE_PROMPTS")
        XCTAssertEqual(HeadsetCapability.rotateToMute.legacyCapabilityString, "CAP_ROTATE_TO_MUTE")
        XCTAssertEqual(HeadsetCapability.equalizerPreset.legacyCapabilityString, "CAP_EQUALIZER_PRESET")
    }

    func testLowBatteryTestProfileReturnsAvailableBatteryStatus() async throws {
        let service = HeadsetControlService()
        let devices = await withCheckedContinuation { continuation in
            HeadsetIOWorker.shared.enqueue { continuation.resume(returning: service.fetchDevices(testProfile: 7)) }
        }
        let battery = try XCTUnwrap(devices.successValue?.first?.battery?.successValue)
        XCTAssertEqual(battery.percentage, 10)
        XCTAssertEqual(battery.status, .available)
    }

    func testNativeBatteryProfilesKeepChargingOfflineAndTimeoutMenuRows() async throws {
        let service = HeadsetControlService()
        let delegate = AppDelegate()
        for (profile, expected) in [
            (2, "\(localized("Battery")): ⚡︎ 50% (\(String(format: localized("%dh until full"), 1)))"),
            (4, "\(localized("Battery")): \(localized("Device offline")) (-3)"),
            (5, "\(localized("Battery")): \(localized("Timed out")) (-4)")
        ] {
            let result = await withCheckedContinuation { continuation in
                HeadsetIOWorker.shared.enqueue { continuation.resume(returning: service.fetchDevices(testProfile: profile)) }
            }
            let device = try XCTUnwrap(result.get().first)
            delegate.latestDevices = [device.menuDictionary]
            let menu = NSMenu()
            delegate.rebuildMenu(menu)
            XCTAssertTrue(menu.items.contains { $0.title == expected }, "Profile \(profile)")
            if profile != 2 {
                XCTAssertFalse(menu.items.contains { $0.title.hasPrefix(localized("Battery") + ":") && $0.title.contains("%") })
            }
        }
    }

    func testNativeLimitedCapabilityProfileShowsOnlySidetoneLightsAndBattery() async throws {
        let service = HeadsetControlService()
        let delegate = AppDelegate()
        var capabilities: [Int: [String]] = [:]
        for profile in [7, 10, 7] {
            let result = await withCheckedContinuation { continuation in
                HeadsetIOWorker.shared.enqueue { continuation.resume(returning: service.fetchDevices(testProfile: profile)) }
            }
            let device = try XCTUnwrap(result.get().first)
            XCTAssertEqual(device.target, .test(profile: profile))
            if let previous = capabilities[profile] { XCTAssertEqual(device.capabilities, previous, "Profile \(profile)") }
            capabilities[profile] = device.capabilities
            guard profile == 10 else { continue }
            XCTAssertEqual(device.capabilities, ["CAP_SIDETONE", "CAP_LIGHTS"])
            XCTAssertNil(device.sidetone)
            XCTAssertTrue(device.failures.isEmpty)
            delegate.latestDevices = [device.menuDictionary]
            let menu = NSMenu()
            delegate.rebuildMenu(menu)
            XCTAssertTrue(menu.items.contains { $0.title == "\(localized("Battery")): 42%" })
            XCTAssertEqual(menu.items.filter(\.hasSubmenu).map(\.title), [localized("Sidetone"), localized("Lights")])
            // The limited profile has no CAP_LIGHT_COLOR, so no color presets.
            XCTAssertEqual(menu.items.first { $0.title == localized("Lights") }?.submenu?.items.map(\.title),
                           [localized("Off"), localized("On")])
        }
        XCTAssertTrue(try XCTUnwrap(capabilities[7]).contains("CAP_EQUALIZER"))
    }

    func testChargingMenuFormatsTimeToFullWithoutUsingTimeToEmpty() async {
        let delegate = AppDelegate()
        for minutes in [nil, -1, 0, 1, 59, 60, 119, 120] as [Int?] {
            let battery = HeadsetBattery(level: 50, status: .charging, timeToEmpty: 720, timeToFull: minutes)
            var device = menuDevice(target: nil)
            device["battery"] = Result<HeadsetBattery, HeadsetFailure>.success(battery)
            delegate.latestDevices = [device]
            let menu = NSMenu()
            delegate.rebuildMenu(menu)
            let suffix: String
            if let minutes, minutes > 0 {
                let duration = minutes < 60 ? localized("<1h until full") : String(format: localized("%dh until full"), minutes / 60)
                suffix = " (\(duration))"
            } else { suffix = "" }
            XCTAssertTrue(menu.items.contains { $0.title == "\(localized("Battery")): ⚡︎ 50%\(suffix)" })
        }
    }

    func testSidetoneMenuMatchesExactLevelAndShowsBetweenPresetsOrUnreadableState() async throws {
        let exact = HeadsetSidetone(level: 64, deviceLevel: 2, deviceMin: 0, deviceMax: 4, levelName: nil)
        let between = HeadsetSidetone(level: 85, deviceLevel: 2, deviceMin: 0, deviceMax: 3, levelName: "Medium")
        let unnamed = HeadsetSidetone(level: 85, deviceLevel: 2, deviceMin: 0, deviceMax: 3, levelName: nil)
        let failure = HeadsetFailure(operation: .sidetone, kind: .native(-4))
        let cases: [(Result<HeadsetSidetone, HeadsetFailure>?, Int?, String)] = [
            (.success(exact), 64, localized("Sidetone")),
            (.success(between), nil, String(format: localized("Sidetone: %@"), between.levelText)),
            (.success(unnamed), nil, String(format: localized("Sidetone: %@"), unnamed.levelText)),
            (nil, nil, localized("Sidetone")),
            (.failure(failure), nil, localized("Sidetone"))
        ]
        let delegate = AppDelegate()
        for (reading, matchedLevel, title) in cases {
            var device = menuDevice(target: .test(profile: 7))
            device["sidetone"] = reading
            delegate.latestDevices = [device]
            let menu = NSMenu()
            delegate.rebuildMenu(menu)
            let item = try XCTUnwrap(menu.items.first { $0.title == title })
            let submenu = try XCTUnwrap(item.submenu)
            let presets = submenu.items.filter { $0.representedObject is HeadsetMenuAction }
            XCTAssertEqual(presets.count, 5)
            let checked = presets.filter { $0.state == .on }
            XCTAssertEqual(checked.compactMap { ($0.representedObject as? HeadsetMenuAction)?.value }, matchedLevel.map { [$0] } ?? [])
            if case .failure = reading {
                XCTAssertEqual(submenu.items.first?.title, failure.message)
            }
            XCTAssertTrue(menu.items.contains { $0.title == localized("Lights") })
        }
    }

    func testSidetoneCommandRefreshesMenuFromObservedLevel() async throws {
        UserDefaults.standard.set(7, forKey: "testMode")
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let controller = HeadsetController(provider: provider, executor: executor)
        let delegate = AppDelegate(headsetController: controller)
        let device = HeadsetDevice(usbID: .testDevice, name: "Fake", vendor: "Vendor", product: "Product", capabilities: ["CAP_SIDETONE"],
                                   sidetone: .success(.init(level: 64, deviceLevel: 2, deviceMin: 0, deviceMax: 4, levelName: nil)), target: .test(profile: 7))
        provider.devices = [device]
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        let submenu = try XCTUnwrap(menu.items.first { $0.title == localized("Sidetone") }?.submenu)
        XCTAssertEqual(submenu.items.first { $0.state == .on }?.title, localized("Medium"))
        let low = try XCTUnwrap(submenu.items.first { ($0.representedObject as? HeadsetMenuAction)?.value == 32 })
        delegate.setSidetoneLevel(low)
        executor.runNext()
        await drainResults()
        XCTAssertEqual(provider.commands.map { $0.0 }, [.sidetone(32)])
        XCTAssertEqual(executor.jobs.count, 1)
        // Read back 96 instead of the requested 32 to ensure the UI trusts the device.
        provider.devices[0].sidetone = .success(.init(level: 96, deviceLevel: 3, deviceMin: 0, deviceMax: 4, levelName: nil))
        executor.runNext()
        await drainResults()
        delegate.rebuildMenu(menu)
        let refreshed = try XCTUnwrap(menu.items.first { $0.title == localized("Sidetone") }?.submenu)
        XCTAssertEqual(refreshed.items.first { $0.state == .on }?.title, localized("High"))
        XCTAssertEqual(provider.profiles, [7, 7])
    }

    func testNativeTestDeviceSidetoneMenuShowsItsCurrentNamedLevel() async throws {
        let service = HeadsetControlService()
        let result = await withCheckedContinuation { continuation in
            HeadsetIOWorker.shared.enqueue { continuation.resume(returning: service.fetchDevices(testProfile: 7)) }
        }
        let device = try XCTUnwrap(result.get().first)
        let delegate = AppDelegate()
        delegate.latestDevices = [device.menuDictionary]
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        let expectedLevel = String(format: localized("%d/128 (%@)"), 85, "Medium")
        let item = try XCTUnwrap(menu.items.first { $0.title == String(format: localized("Sidetone: %@"), expectedLevel) })
        XCTAssertFalse(try XCTUnwrap(item.submenu).items.contains { $0.state == .on })
    }

    func testEveryMenuControlKeepsItsOwnDeviceAfterSnapshotChanges() async throws {
        UserDefaults.standard.set(0, forKey: "testMode")
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let controller = HeadsetController(provider: provider, executor: executor)
        let delegate = AppDelegate(headsetController: controller)
        let a = HeadsetTarget.physical(HeadsetUSBID(vendor: 1, product: 2), attachmentID: 11)
        let b = HeadsetTarget.physical(HeadsetUSBID(vendor: 3, product: 4), attachmentID: 22)
        delegate.latestDevices = [menuDevice(target: a), menuDevice(target: b)]
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        let titles = ["Sidetone", "Lights", "Inactive Time", "Voice Prompts", "Rotate to Mute", "Equalizer", "Noise cancelling", "Headset volume"]
        let controls = try titles.map { title in
            try XCTUnwrap(menu.items.last { $0.title == localized(title) }?.submenu?.items.first)
        }
        // A cached menu item must never be retargeted using the current array.
        delegate.latestDevices = [menuDevice(target: a)]
        for item in controls {
            XCTAssertEqual((item.representedObject as? HeadsetMenuAction)?.target, b)
            let selector = try XCTUnwrap(item.action)
            _ = delegate.perform(selector, with: item)
        }
        XCTAssertEqual(executor.jobs.count, 8)
        while !executor.jobs.isEmpty { executor.runNext() }
        XCTAssertEqual(provider.commands.map { $0.1 }, Array(repeating: b, count: 8))
        XCTAssertEqual(provider.commands.map { $0.0 }, [.sidetone(0), .lights(false), .inactiveTime(0), .voicePrompts(false), .rotateToMute(false), .equalizerPreset(0), .anc(0), .headsetVolume(0)])
    }

    func testUnknownTargetAndOldTestMenuCannotEnqueueHardwareCommands() async throws {
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let delegate = AppDelegate(headsetController: HeadsetController(provider: provider, executor: executor))
        delegate.latestDevices = [menuDevice(target: nil)]
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        let unknown = try XCTUnwrap(menu.items.first { $0.title == localized("Lights") }?.submenu?.items.first)
        XCTAssertNil(unknown.action)
        delegate.setLights(unknown)
        XCTAssertTrue(executor.jobs.isEmpty)

        delegate.latestDevices = [menuDevice(target: .test(profile: 7))]
        delegate.rebuildMenu(menu)
        let testItem = try XCTUnwrap(menu.items.first { $0.title == localized("Lights") }?.submenu?.items.first)
        UserDefaults.standard.set(0, forKey: "testMode")
        delegate.setLights(testItem)
        XCTAssertTrue(executor.jobs.isEmpty)
        UserDefaults.standard.set(7, forKey: "testMode")
        delegate.setLights(testItem)
        executor.runNext()
        XCTAssertEqual(provider.commands.first?.1, .test(profile: 7))
        XCTAssertEqual(provider.commands.first?.2, 7)
    }

    func testStopInvalidatesTimerAndDiscardsLateUIUpdate() async {
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let delegate = AppDelegate(headsetController: HeadsetController(provider: provider, executor: executor))
        delegate.startStatusUpdateTimer()
        let timer = delegate.statusUpdateTimer
        delegate.updateStatusItem()
        executor.runNext() // Native result queued for delivery to the main actor.
        var stopped = false
        delegate.stop { stopped = true }
        XCTAssertEqual(timer?.isValid, false)
        XCTAssertNil(delegate.statusUpdateTimer)
        XCTAssertFalse(stopped)
        delegate.updateStatusItem()
        delegate.startStatusUpdateTimer()
        await Task.yield()
        XCTAssertNil(delegate.latestDevices)
        XCTAssertTrue(executor.jobs.isEmpty)
        executor.finishStop()
        await withCheckedContinuation { continuation in
            HeadsetMainRunLoop.perform { continuation.resume() }
        }
        XCTAssertTrue(stopped)
        XCTAssertEqual(provider.shutdownCount, 1)
    }

    func testModeChangeBeforeResultDeliveryDiscardsTheOldSnapshot() async {
        UserDefaults.standard.set(0, forKey: "testMode")
        let provider = RecordingHeadsetProvider()
        provider.devices = [HeadsetDevice(usbID: .init(vendor: 1, product: 2), name: "Physical", vendor: "Vendor", product: "Product", capabilities: [])]
        let executor = ManualHeadsetExecutor()
        let delegate = AppDelegate(headsetController: HeadsetController(provider: provider, executor: executor))
        delegate.updateStatusItem()
        executor.runNext()
        UserDefaults.standard.set(7, forKey: "testMode")
        await withCheckedContinuation { continuation in
            HeadsetMainRunLoop.perform { continuation.resume() }
        }
        XCTAssertEqual(delegate.latestDevices?.count, 0)
        XCTAssertEqual(executor.jobs.count, 1)
        provider.devices = [HeadsetDevice(usbID: .testDevice, name: "Fake", vendor: "Vendor", product: "Product", capabilities: [], target: .test(profile: 7))]
        executor.runNext()
        await withCheckedContinuation { continuation in
            HeadsetMainRunLoop.perform { continuation.resume() }
        }
        XCTAssertEqual(delegate.latestDevices?.first?["device"] as? String, "Fake")
        XCTAssertEqual(provider.profiles, [0, 7])
    }

    func testDiscoveryFailureOffersRetryInsteadOfReportingNoDevices() async {
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let delegate = AppDelegate(headsetController: HeadsetController(provider: provider, executor: executor))
        provider.fetchFailure = .init(operation: .discovery, kind: .native(-5))
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        XCTAssertEqual(delegate.refreshFailure, provider.fetchFailure)
        XCTAssertTrue(menu.items.contains { $0.title == localized("Retry refresh") })
        XCTAssertFalse(menu.items.contains { $0.title == localized("No devices found") })
        provider.fetchFailure = nil
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        delegate.rebuildMenu(menu)
        XCTAssertTrue(menu.items.contains { $0.title == localized("No devices found") })
        XCTAssertNil(delegate.refreshFailure)
    }

    func testCommandFailureIsVisibleAndSuccessClearsIt() async throws {
        UserDefaults.standard.set(0, forKey: "testMode")
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let delegate = AppDelegate(headsetController: HeadsetController(provider: provider, executor: executor))
        delegate.latestDevices = [menuDevice(target: .physical(.init(vendor: 1, product: 2), attachmentID: 11))]
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        let item = try XCTUnwrap(menu.items.first { $0.title == localized("Lights") }?.submenu?.items.first)
        provider.commandResult = .failure(.init(operation: .command, kind: .native(-4)))
        delegate.setLights(item)
        executor.runNext()
        await drainResults()
        XCTAssertTrue(delegate.commandFailure?.contains("-4") == true)
        delegate.rebuildMenu(menu)
        XCTAssertTrue(menu.items.contains { $0.title.contains("-4") })
        provider.commandResult = .success(())
        delegate.setLights(item)
        executor.runNext()
        await drainResults()
        XCTAssertNil(delegate.commandFailure)
    }

    func testEqualizerMenuPreservesExplicitOrderAndNeverInventsUnknownIndices() async throws {
        let delegate = AppDelegate()
        var device = menuDevice(target: .test(profile: 7))
        device["capabilities"] = ["CAP_EQUALIZER_PRESET"]
        device["equalizerPresets"] = Result<[HeadsetEqualizerPreset], HeadsetFailure>.success([
            .init(index: 3, name: "Voice"), .init(index: 1, name: "Flat"), .init(index: 2, name: "Flat")
        ])
        delegate.latestDevices = [device]
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        var items = try XCTUnwrap(menu.items.first { $0.title == localized("Equalizer Preset") }?.submenu).items
        XCTAssertEqual(items.map(\.title), ["Voice", "Flat", "Flat"])
        XCTAssertEqual(items.map { ($0.representedObject as? HeadsetMenuAction)?.value }, [3, 1, 2])
        device["equalizerPresets"] = Result<[HeadsetEqualizerPreset], HeadsetFailure>.success([])
        delegate.latestDevices = [device]
        delegate.rebuildMenu(menu)
        items = try XCTUnwrap(menu.items.first { $0.title == localized("Equalizer Preset") }?.submenu).items
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items.first?.action)
        XCTAssertNil(items.first?.representedObject)
    }

    func testMenuNeverDisplaysInvalidOrUnavailablePercentages() async {
        let delegate = AppDelegate()
        let states: [(HeadsetBattery, String?)] = [
            (.init(level: 0, status: .available), "0%"),
            (.init(level: 10, status: .available), "10%"),
            (.init(level: 0, status: .unavailable), nil),
            (.init(level: 42, status: .unknown(999)), nil),
            (.init(level: -1, status: .available), nil),
            (.init(level: 101, status: .available), nil),
            (.init(level: -1, status: .charging), nil)
        ]
        for (battery, percentage) in states {
            var device = menuDevice(target: nil)
            device["battery"] = Result<HeadsetBattery, HeadsetFailure>.success(battery)
            delegate.latestDevices = [device]
            let menu = NSMenu()
            delegate.rebuildMenu(menu)
            let row = menu.items.first { $0.title.hasPrefix(localized("Battery") + ":") }
            XCTAssertNotNil(row)
            if let percentage { XCTAssertTrue(row?.title.contains(percentage) == true) }
            else { XCTAssertFalse(row?.title.contains("%") == true) }
        }
    }

    func testNotificationPreferenceIsRecheckedBeforeAsyncSubmission() async {
        UserDefaults.standard.set(7, forKey: "testMode")
        UserDefaults.standard.set(true, forKey: "notifyOnLowBattery")
        let provider = RecordingHeadsetProvider()
        provider.devices = [HeadsetDevice(usbID: .testDevice, name: "Fake", vendor: "Vendor", product: "Product", capabilities: [],
                                          battery: .success(.init(level: 10, status: .available)), target: .test(profile: 7))]
        let executor = ManualHeadsetExecutor()
        let delivery = RecordingNotificationDelivery()
        let delegate = AppDelegate(headsetController: HeadsetController(provider: provider, executor: executor), notificationDelivery: delivery)
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        XCTAssertEqual(delivery.authorizations.count, 1)
        UserDefaults.standard.set(false, forKey: "notifyOnLowBattery")
        delivery.authorizations[0](.success(true))
        XCTAssertTrue(delivery.submissions.isEmpty)
    }

    func testPendingAuthorizationChecksLatestBatteryAgainstChangedThreshold() async throws {
        UserDefaults.standard.set(7, forKey: "testMode")
        UserDefaults.standard.set(true, forKey: "notifyOnLowBattery")
        UserDefaults.standard.set(25, forKey: "lowBatteryThreshold")
        let provider = RecordingHeadsetProvider()
        provider.devices = [HeadsetDevice(usbID: .testDevice, name: "Fake", vendor: "Vendor", product: "Product", capabilities: [],
                                          battery: .success(.init(level: 10, status: .available)), target: .test(profile: 7))]
        let executor = ManualHeadsetExecutor()
        let delivery = RecordingNotificationDelivery()
        let delegate = AppDelegate(headsetController: HeadsetController(provider: provider, executor: executor), notificationDelivery: delivery)
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        provider.devices[0].battery = .success(.init(level: 20, status: .available))
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        XCTAssertEqual(delivery.authorizations.count, 1)

        // Complete authorization before a defaults observer can suspend it.
        UserDefaults.standard.set(15, forKey: "lowBatteryThreshold")
        let authorize = try XCTUnwrap(delivery.authorizations.first)
        authorize(.success(true))
        XCTAssertTrue(delivery.submissions.isEmpty)

        // Rejecting the old attempt must leave the next genuine low reading
        // eligible, rather than keeping an unresolved pending authorization.
        provider.devices[0].battery = .success(.init(level: 10, status: .available))
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        XCTAssertEqual(delivery.authorizations.count, 2)
        if delivery.authorizations.count == 2 {
            delivery.authorizations[1](.success(true))
            XCTAssertEqual(delivery.submissions, [LowBatteryNotice(target: .test(profile: 7), level: 10)])
        }
        delegate.stop()
        executor.finishStop()
        await drainResults()
    }

    func testDisablingAlertsClearsFailuresBeforeRefreshAndRejectsLateWarnings() async {
        for failure in [NotificationFailure.denied, .system(domain: "Test", code: 1, description: "Rejected")] {
            UserDefaults.standard.set(7, forKey: "testMode")
            UserDefaults.standard.set(true, forKey: "notifyOnLowBattery")
            let provider = RecordingHeadsetProvider()
            provider.devices = [HeadsetDevice(usbID: .testDevice, name: "Fake", vendor: "Vendor", product: "Product", capabilities: [],
                                              battery: .success(.init(level: 10, status: .available)), target: .test(profile: 7))]
            let executor = ManualHeadsetExecutor()
            let delivery = RecordingNotificationDelivery()
            let delegate = AppDelegate(headsetController: HeadsetController(provider: provider, executor: executor), notificationDelivery: delivery)
            delegate.updateStatusItem()
            executor.runNext()
            await drainResults()
            if failure == .denied {
                delivery.authorizations[0](.success(false))
            } else {
                delivery.authorizations[0](.success(true))
                delivery.completions[0](.failure(failure))
            }
            XCTAssertEqual(delegate.notificationFailure, failure)
            let menu = NSMenu()
            delegate.rebuildMenu(menu)
            XCTAssertTrue(menu.items.contains { $0.title == failure.message })

            UserDefaults.standard.set(false, forKey: "notifyOnLowBattery")
            delegate.handleUserDefaultsChanged(Notification(name: UserDefaults.didChangeNotification))
            await drainResults()
            // Hold the refresh pending: clearing feedback must not wait for HID.
            XCTAssertEqual(executor.jobs.count, 1)
            XCTAssertNil(delegate.notificationFailure)
            delegate.rebuildMenu(menu)
            XCTAssertFalse(menu.items.contains { $0.title == failure.message })
            executor.runNext()
            await drainResults()

            UserDefaults.standard.set(true, forKey: "notifyOnLowBattery")
            delegate.handleUserDefaultsChanged(Notification(name: UserDefaults.didChangeNotification))
            await drainResults()
            executor.runNext()
            await drainResults()
            XCTAssertEqual(delivery.authorizations.count, 2)
            // Authorization can complete before the queued defaults observer.
            UserDefaults.standard.set(false, forKey: "notifyOnLowBattery")
            delivery.authorizations[1](.success(false))
            XCTAssertNil(delegate.notificationFailure)
            delegate.rebuildMenu(menu)
            XCTAssertFalse(menu.items.contains { $0.title == NotificationFailure.denied.message })
            delegate.stop()
            executor.finishStop()
            await drainResults()
        }
    }

    func testNotificationWarningClearsOnlyAfterItsOwnDeviceSucceeds() async throws {
        for failsAuthorization in [true, false] {
            for retryCompletesWhileEligible in [true, false] {
                UserDefaults.standard.set(0, forKey: "testMode")
                UserDefaults.standard.set(true, forKey: "notifyOnLowBattery")
                UserDefaults.standard.set(25, forKey: "lowBatteryThreshold")
                let a = HeadsetDevice(usbID: .init(vendor: 1, product: 2), name: "A", vendor: "Vendor", product: "Product", capabilities: [],
                                      battery: .success(.init(level: 10, status: .available)),
                                      target: .physical(.init(vendor: 1, product: 2), attachmentID: 11))
                let b = HeadsetDevice(usbID: .init(vendor: 3, product: 4), name: "B", vendor: "Vendor", product: "Product", capabilities: [],
                                      battery: .success(.init(level: 10, status: .available)),
                                      target: .physical(.init(vendor: 3, product: 4), attachmentID: 22))
                let provider = RecordingHeadsetProvider()
                let executor = ManualHeadsetExecutor()
                let delivery = RecordingNotificationDelivery()
                let delegate = AppDelegate(headsetController: HeadsetController(provider: provider, executor: executor), notificationDelivery: delivery)
                func refresh(_ devices: [HeadsetDevice]) async {
                    provider.devices = devices
                    delegate.updateStatusItem()
                    executor.runNext()
                    await drainResults()
                }

                await refresh([a, b])
                let authorizeA = try XCTUnwrap(delivery.authorizations.first)
                authorizeA(.success(true))
                await refresh([b, a])
                let authorizeB = try XCTUnwrap(delivery.authorizations.dropFirst().first)
                let failure: NotificationFailure = failsAuthorization ? .denied : .system(domain: "Test", code: 1, description: "Rejected")
                if failsAuthorization {
                    authorizeB(.success(false))
                } else {
                    authorizeB(.success(true))
                    let failB = try XCTUnwrap(delivery.completions.dropFirst().first)
                    failB(.failure(failure))
                }
                XCTAssertEqual(delegate.notificationFailure, failure)

                // A becomes eligible again before its older submission succeeds.
                // That success must not clear the warning produced by B.
                await refresh([a, b])
                let completeA = try XCTUnwrap(delivery.completions.first)
                completeA(.success(()))
                XCTAssertEqual(delegate.notificationFailure, failure)
                let menu = NSMenu()
                delegate.rebuildMenu(menu)
                XCTAssertTrue(menu.items.contains { $0.title == failure.message })

                await refresh([b, a])
                XCTAssertEqual(delivery.authorizations.count, 3)
                let retryB = try XCTUnwrap(delivery.authorizations.dropFirst(2).first)
                retryB(.success(true))
                if !retryCompletesWhileEligible { await refresh([a, b]) }
                let completeB = try XCTUnwrap(delivery.completions.last)
                completeB(.success(()))
                XCTAssertNil(delegate.notificationFailure)
                delegate.rebuildMenu(menu)
                XCTAssertFalse(menu.items.contains { $0.title == failure.message })
                delegate.stop()
                executor.finishStop()
                await drainResults()
            }
        }
    }

    private func drainResults() async {
        await withCheckedContinuation { continuation in HeadsetMainRunLoop.perform { continuation.resume() } }
    }

    private func menuDevice(target: HeadsetTarget?) -> [String: Any] {
        var device: [String: Any] = [
            "device": "Headset", "vendor": "Vendor", "product": "Product",
            "capabilities": HeadsetCapability.menuCapabilities.map { $0.legacyCapabilityString },
            "equalizerPresets": Result<[HeadsetEqualizerPreset], HeadsetFailure>.success([.init(index: 0, name: "Flat")])
        ]
        device["control_target"] = target
        return device
    }

}
