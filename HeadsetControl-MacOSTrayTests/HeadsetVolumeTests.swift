import AppKit
import HeadsetControlCLib
import XCTest
@testable import HeadsetControl_MacOSTray

@MainActor final class HeadsetVolumeTests: XCTestCase {
    private func volume(_ level: Int) -> HeadsetVolume {
        HeadsetVolume(level: level, minLevel: 0, maxLevel: 128, deviceLevel: 15, deviceMin: 0, deviceMax: 21)
    }

    private func device(_ reading: Result<HeadsetVolume, HeadsetFailure>?, profile: Int = 7) -> HeadsetDevice {
        HeadsetDevice(usbID: .testDevice, name: "Test", vendor: "Vendor", product: "Product",
                      capabilities: ["CAP_HEADSET_VOLUME"], headsetVolume: reading, target: .test(profile: profile))
    }

    private func drainResults() async {
        await withCheckedContinuation { continuation in HeadsetMainRunLoop.perform { continuation.resume() } }
    }

    func testDefaultsRegisterRepairAndPreserveCustomAndHiddenPresets() throws {
        let name = "HeadsetVolumeDefaults.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        AppDefaults.register(in: store)
        XCTAssertEqual(AppDefaults.headsetVolumeKeys.map { store.integer(forKey: $0) }, [0, 32, 64, 96, 128])
        store.set(-1, forKey: "headsetVolumeOff")
        store.set("invalid", forKey: "headsetVolumeLow")
        store.set(91, forKey: "headsetVolumeMid")
        store.set(Int.min, forKey: "headsetVolumeHigh")
        store.set(Int.max, forKey: "headsetVolumeMax")
        AppDefaults.validate(in: store)
        XCTAssertEqual(AppDefaults.headsetVolumeKeys.map { store.integer(forKey: $0) }, [-1, 32, 91, -1, 128])
        XCTAssertEqual(store.integer(forKey: "sidetoneMid"), 64)
        XCTAssertEqual(store.integer(forKey: "microphoneVolumeMid"), 64)
    }

    func testVolumeDecoderPreservesNativeStepsAndMatchesOnlyExactPresets() throws {
        let result = try HeadsetVolume.decode(level: 91, minLevel: 0, maxLevel: 128, deviceLevel: 15, deviceMin: 0, deviceMax: 21).get()
        XCTAssertEqual(result, volume(91))
        XCTAssertNil(result.matchingPresetIndex(in: [0, 32, 64, 96, 128]))
        XCTAssertEqual(result.matchingPresetIndex(in: [0, 91, 91, 128]), 1)
        for (level, minLevel, maxLevel, deviceLevel, deviceMin, deviceMax) in [
            (-1, 0, 128, 0, 0, 21), (129, 0, 128, 0, 0, 21),
            (64, -1, 128, 0, 0, 21), (64, 0, 129, 0, 0, 21),
            (64, 128, 0, 0, 0, 21), (64, 65, 128, 0, 0, 21),
            (64, 0, 128, 22, 0, 21), (64, 0, 128, 0, 21, 0), (64, 0, 128, 0, -1, 21)
        ] {
            let decoded = HeadsetVolume.decode(level: level, minLevel: minLevel, maxLevel: maxLevel,
                                               deviceLevel: deviceLevel, deviceMin: deviceMin, deviceMax: deviceMax)
            XCTAssertEqual(decoded.failureValue?.operation, .headsetVolume)
            XCTAssertFalse(decoded.isSuccess)
        }
        for level in [0, 128] {
            XCTAssertTrue(HeadsetVolume.decode(level: level, minLevel: 0, maxLevel: 128,
                                              deviceLevel: 0, deviceMin: 0, deviceMax: 21).isSuccess)
        }
    }

    func testNativeReadableAndWriteOnlyProfilesAndCommandErrors() async throws {
        let service = HeadsetControlService()
        let results = await withCheckedContinuation { continuation in
            HeadsetIOWorker.shared.enqueue {
                let readings = [7, 6, 1].map { service.fetchDevices(testProfile: $0) }
                for profile in [7, 6] {
                    for level in [0, 32, 64, 96, 128] {
                        XCTAssertTrue(service.perform(.headsetVolume(level), on: .test(profile: profile), testProfile: profile).isSuccess)
                    }
                }
                XCTAssertEqual(service.perform(.headsetVolume(64), on: .test(profile: 1), testProfile: 1).failureValue?.kind, .native(-5))
                for level in [Int.min, -1, 129, 255, 256, Int.max] {
                    XCTAssertEqual(service.perform(.headsetVolume(level), on: .test(profile: 7), testProfile: 7).failureValue?.kind,
                                   .native(HSC_RESULT_INVALID_PARAM.rawValue))
                }
                continuation.resume(returning: readings)
            }
        }
        let readable = try XCTUnwrap(results[0].get().first)
        XCTAssertEqual(try XCTUnwrap(readable.headsetVolume).get(), volume(77))
        XCTAssertTrue(readable.capabilities.contains("CAP_HEADSET_VOLUME"))
        let writeOnly = try XCTUnwrap(results[1].get().first)
        XCTAssertNil(writeOnly.headsetVolume) // A getter call would have produced NOT_SUPPORTED, not nil.
        XCTAssertTrue(writeOnly.capabilities.contains("CAP_HEADSET_VOLUME"))
        let failed = try XCTUnwrap(results[2].get().first)
        let error = HeadsetFailure(operation: .headsetVolume, kind: .native(-5))
        XCTAssertEqual(failed.headsetVolume?.failureValue, error)
        XCTAssertTrue(failed.failures.contains(error))
    }

    func testMenuShowsObservedValueAndErrorsButNoWriteOnlyState() throws {
        let store = AppDefaults.standard
        let saved = AppDefaults.headsetVolumeKeys.map { store.object(forKey: $0) }
        defer { for (key, value) in zip(AppDefaults.headsetVolumeKeys, saved) { store.set(value, forKey: key) } }
        for (key, value) in zip(AppDefaults.headsetVolumeKeys, AppDefaults.headsetVolumeValues) { store.set(value, forKey: key) }
        let delegate = AppDelegate()
        let failure = HeadsetFailure(operation: .headsetVolume, kind: .native(-4))
        let title = NSLocalizedString("Headset volume", comment: "")
        let between = String(format: NSLocalizedString("Headset volume: %@", comment: ""), volume(91).levelText)
        let cases: [(Result<HeadsetVolume, HeadsetFailure>?, String, [Int])] = [
            (.success(volume(64)), title, [64]), (.success(volume(91)), between, []),
            (.failure(failure), title, []), (nil, title, [])
        ]
        for (reading, expectedTitle, checkedLevels) in cases {
            delegate.latestDevices = [device(reading).menuDictionary]
            let menu = NSMenu()
            delegate.rebuildMenu(menu)
            let submenu = try XCTUnwrap(menu.items.first { $0.title == expectedTitle }?.submenu)
            XCTAssertEqual(submenu.items.compactMap { ($0.representedObject as? HeadsetMenuAction)?.value }, [0, 32, 64, 96, 128])
            XCTAssertEqual(submenu.items.filter { $0.state == .on }.compactMap { ($0.representedObject as? HeadsetMenuAction)?.value }, checkedLevels)
            if case .failure = reading { XCTAssertEqual(submenu.items.first?.title, failure.message) }
        }
        store.set(-1, forKey: "headsetVolumeOff")
        store.set(64, forKey: "headsetVolumeLow")
        delegate.latestDevices = [device(.success(volume(64))).menuDictionary]
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        let submenu = try XCTUnwrap(menu.items.first { $0.title == title }?.submenu)
        XCTAssertEqual(submenu.items.compactMap { ($0.representedObject as? HeadsetMenuAction)?.value }, [64, 64, 96, 128])
        XCTAssertEqual(submenu.items.map(\.state), [.on, .off, .off, .off])
        var ambiguous = device(nil).menuDictionary
        ambiguous.removeValue(forKey: "control_target")
        delegate.latestDevices = [ambiguous]
        delegate.rebuildMenu(menu)
        XCTAssertTrue(try XCTUnwrap(menu.items.first { $0.title == title }?.submenu).items.allSatisfy { $0.action == nil })
        ambiguous["capabilities"] = [String]()
        delegate.latestDevices = [ambiguous]
        delegate.rebuildMenu(menu)
        XCTAssertFalse(menu.items.contains { $0.title == title })
    }

    func testNativeMenuChecksMatchingPresetAndProfileSixStaysUncheckedAfterWrites() async throws {
        let store = AppDefaults.standard
        let saved = (AppDefaults.headsetVolumeKeys + ["testMode"]).map { store.object(forKey: $0) }
        defer { for (key, value) in zip(AppDefaults.headsetVolumeKeys + ["testMode"], saved) { store.set(value, forKey: key) } }
        for (key, value) in zip(AppDefaults.headsetVolumeKeys, AppDefaults.headsetVolumeValues) { store.set(value, forKey: key) }
        // The test device reports 77/128 (native step 15/21). Configure an exact
        // match rather than pretending that the default 96 preset is current.
        store.set(77, forKey: "headsetVolumeHigh")
        for profile in [7, 6] {
            store.set(profile, forKey: "testMode")
            let controller = HeadsetController(provider: HeadsetControlService(), executor: HeadsetIOWorker.shared)
            let delegate = AppDelegate(headsetController: controller, notificationDelivery: RecordingNotificationDelivery())
            let originalRefresh = controller.onRefresh
            let initial = expectation(description: "initial volume profile \(profile)")
            controller.onRefresh = { result in originalRefresh?(result); initial.fulfill() }
            delegate.updateStatusItem()
            await fulfillment(of: [initial], timeout: 5)
            let menu = NSMenu()
            delegate.rebuildMenu(menu)
            let submenu = try XCTUnwrap(menu.items.first { $0.title == NSLocalizedString("Headset volume", comment: "") }?.submenu)
            XCTAssertEqual(submenu.items.filter { $0.state == .on }.map(\.title), profile == 7 ? [NSLocalizedString("High", comment: "")] : [])
            let low = try XCTUnwrap(submenu.items.first { ($0.representedObject as? HeadsetMenuAction)?.value == 32 })
            let refreshed = expectation(description: "read after volume write \(profile)")
            controller.onRefresh = { result in originalRefresh?(result); refreshed.fulfill() }
            delegate.setHeadsetVolume(low)
            await fulfillment(of: [refreshed], timeout: 5)
            XCTAssertNil(delegate.commandFailure)
            delegate.rebuildMenu(menu)
            let updated = try XCTUnwrap(menu.items.first { $0.title == NSLocalizedString("Headset volume", comment: "") }?.submenu)
            // The test getter returns the same observed step after any write.
            XCTAssertEqual(updated.items.filter { $0.state == .on }.map(\.title), profile == 7 ? [NSLocalizedString("High", comment: "")] : [])
        }
    }

    func testFailedVolumeCommandPreservesFeedbackWithoutSchedulingReadback() async throws {
        UserDefaults.standard.set(7, forKey: "testMode")
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let delegate = AppDelegate(headsetController: HeadsetController(provider: provider, executor: executor))
        delegate.latestDevices = [device(nil).menuDictionary]
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        let item = try XCTUnwrap(menu.items.first { $0.title == NSLocalizedString("Headset volume", comment: "") }?.submenu?.items.first)
        provider.commandResult = .failure(.init(operation: .command, kind: .native(-5)))
        delegate.setHeadsetVolume(item)
        XCTAssertTrue(provider.commands.isEmpty)
        executor.runNext()
        await drainResults()
        XCTAssertEqual(provider.commands.map { $0.0 }, [.headsetVolume(0)])
        XCTAssertEqual(provider.commands.first?.1, .test(profile: 7))
        XCTAssertTrue(delegate.commandFailure?.contains("-5") == true)
        XCTAssertTrue(executor.jobs.isEmpty)
        delegate.stop()
        executor.finishStop()
        await drainResults()
    }
}
