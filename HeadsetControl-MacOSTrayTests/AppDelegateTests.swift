import AppKit
import XCTest
@testable import HeadsetControl_MacOSTray

@MainActor class AppDelegateTests: XCTestCase {
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
        let appDelegate = AppDelegate()
        appDelegate.latestDevices = []
        let menu = NSMenu()

        appDelegate.menuNeedsUpdate(menu)

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

        appDelegate.menuNeedsUpdate(menu)

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

        appDelegate.menuNeedsUpdate(menu)

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
            "battery": Result<HeadsetBattery, HeadsetFailure>.success(.init(level: 44, status: .available, timeToEmpty: 119)),
            "capabilities": []
        ]]
        let menu = NSMenu()

        appDelegate.menuNeedsUpdate(menu)

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
        XCTAssertEqual(HeadsetCapability.sidetone.legacyCapabilityString, "CAP_SIDETONE")
        XCTAssertEqual(HeadsetCapability.lights.legacyCapabilityString, "CAP_LIGHTS")
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
        delegate.menuNeedsUpdate(menu)
        let titles = ["Sidetone", "Lights", "Inactive Time", "Voice Prompts", "Rotate to Mute", "Equalizer Preset"]
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
        XCTAssertEqual(executor.jobs.count, 6)
        while !executor.jobs.isEmpty { executor.runNext() }
        XCTAssertEqual(provider.commands.map { $0.1 }, Array(repeating: b, count: 6))
        XCTAssertEqual(provider.commands.map { $0.0 }, [.sidetone(0), .lights(false), .inactiveTime(0), .voicePrompts(false), .rotateToMute(false), .equalizerPreset(0)])
    }

    func testUnknownTargetAndOldTestMenuCannotEnqueueHardwareCommands() async throws {
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let delegate = AppDelegate(headsetController: HeadsetController(provider: provider, executor: executor))
        delegate.latestDevices = [menuDevice(target: nil)]
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        let unknown = try XCTUnwrap(menu.items.first { $0.title == localized("Lights") }?.submenu?.items.first)
        XCTAssertNil(unknown.action)
        delegate.setLights(unknown)
        XCTAssertTrue(executor.jobs.isEmpty)

        delegate.latestDevices = [menuDevice(target: .test(profile: 7))]
        delegate.menuNeedsUpdate(menu)
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
            DispatchQueue.main.async { continuation.resume() }
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
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(delegate.latestDevices?.count, 0)
        XCTAssertEqual(executor.jobs.count, 1)
        provider.devices = [HeadsetDevice(usbID: .testDevice, name: "Fake", vendor: "Vendor", product: "Product", capabilities: [], target: .test(profile: 7))]
        executor.runNext()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
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
        delegate.menuNeedsUpdate(menu)
        XCTAssertEqual(delegate.refreshFailure, provider.fetchFailure)
        XCTAssertTrue(menu.items.contains { $0.title == localized("Retry refresh") })
        XCTAssertFalse(menu.items.contains { $0.title == localized("No devices found") })
        provider.fetchFailure = nil
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        delegate.menuNeedsUpdate(menu)
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
        delegate.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.items.first { $0.title == localized("Lights") }?.submenu?.items.first)
        provider.commandResult = .failure(.init(operation: .command, kind: .native(-4)))
        delegate.setLights(item)
        executor.runNext()
        await drainResults()
        XCTAssertTrue(delegate.commandFailure?.contains("-4") == true)
        delegate.menuNeedsUpdate(menu)
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
        device["equalizerPresets"] = Result<[HeadsetEqualizerPreset], HeadsetFailure>.success([
            .init(index: 3, name: "Voice"), .init(index: 1, name: "Flat"), .init(index: 2, name: "Flat")
        ])
        delegate.latestDevices = [device]
        let menu = NSMenu()
        delegate.menuNeedsUpdate(menu)
        var items = try XCTUnwrap(menu.items.first { $0.title == localized("Equalizer Preset") }?.submenu).items
        XCTAssertEqual(items.map(\.title), ["Voice", "Flat", "Flat"])
        XCTAssertEqual(items.map { ($0.representedObject as? HeadsetMenuAction)?.value }, [3, 1, 2])
        device["equalizerPresets"] = Result<[HeadsetEqualizerPreset], HeadsetFailure>.success([])
        delegate.latestDevices = [device]
        delegate.menuNeedsUpdate(menu)
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
            delegate.menuNeedsUpdate(menu)
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
            delegate.menuNeedsUpdate(menu)
            XCTAssertTrue(menu.items.contains { $0.title == failure.message })

            UserDefaults.standard.set(false, forKey: "notifyOnLowBattery")
            delegate.handleUserDefaultsChanged(Notification(name: UserDefaults.didChangeNotification))
            await drainResults()
            // Hold the refresh pending: clearing feedback must not wait for HID.
            XCTAssertEqual(executor.jobs.count, 1)
            XCTAssertNil(delegate.notificationFailure)
            delegate.menuNeedsUpdate(menu)
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
            delegate.menuNeedsUpdate(menu)
            XCTAssertFalse(menu.items.contains { $0.title == NotificationFailure.denied.message })
            delegate.stop()
            executor.finishStop()
            await drainResults()
        }
    }

    private func drainResults() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
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
