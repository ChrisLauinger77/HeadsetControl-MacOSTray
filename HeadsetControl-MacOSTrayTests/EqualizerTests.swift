import AppKit
import HeadsetControlCLib
import XCTest
@testable import HeadsetControl_MacOSTray

nonisolated enum EqualizerFixtures {
    static let usbID = HeadsetUSBID(vendor: 1, product: 2)
    static let graphic = GraphicEqualizerInfo(count: 3, baseline: 0, step: 0.5, minimum: -12, maximum: 12)
    static let parametric = ParametricEqualizerInfo(count: 3, baseline: 0, step: 0.5, minimum: -12, maximum: 12,
                                                   qMinimum: 0.5, qMaximum: 10, frequencyMinimum: 20, frequencyMaximum: 20000,
                                                   filterMask: (1 << 0) | (1 << 2) | (1 << 4))
    static let curve = EqualizerCurve.graphic(graphic, [1, 0, -2])

    static func device(id: HeadsetUSBID = usbID, attachment: UInt64 = 11) -> HeadsetDevice {
        HeadsetDevice(usbID: id, name: "Headset", vendor: "Vendor", product: "Product",
                      capabilities: ["CAP_EQUALIZER", "CAP_PARAMETRIC_EQUALIZER", "CAP_EQUALIZER_PRESET"],
                      equalizerPresets: .success([.init(index: 0, name: "Flat", bands: .success([0, 0, 0])),
                                                  .init(index: 1, name: "Bass", bands: .success([2, 0, -1]))]),
                      equalizerInfo: .success(graphic), parametricEqualizerInfo: .success(parametric),
                      target: id == .testDevice ? .test(profile: 7) : .physical(id, attachmentID: attachment))
    }
}

final class EqualizerValidationTests: XCTestCase {
    func testGraphicMetadataAndValuesRejectMalformedNativeOrSavedData() {
        for count in [-1, 0, 65, Int.max] {
            XCTAssertFalse(GraphicEqualizerInfo(count: count, baseline: 0, step: 1, minimum: -12, maximum: 12).isValid)
        }
        for step in [0, -1, .nan, .infinity] as [Double] {
            XCTAssertFalse(GraphicEqualizerInfo(count: 3, baseline: 0, step: step, minimum: -12, maximum: 12).isValid)
        }
        XCTAssertFalse(GraphicEqualizerInfo(count: 3, baseline: 13, step: 1, minimum: -12, maximum: 12).isValid)
        XCTAssertFalse(GraphicEqualizerInfo(count: 3, baseline: 0, step: 1, minimum: 12, maximum: -12).isValid)
        XCTAssertFalse(GraphicEqualizerInfo(count: 3, baseline: 0, step: 1, minimum: -.infinity, maximum: .infinity).isValid)
        let info = EqualizerFixtures.graphic
        XCTAssertTrue(info.accepts([-12, 0, 12]))
        for bands in [[], [0], [0, 0, 0, 0], [0.1, 0, 0], [12.5, 0, 0], [.nan, 0, 0], [.infinity, 0, 0]] {
            XCTAssertFalse(info.accepts(bands))
        }
        let floatStep = GraphicEqualizerInfo(count: 1, baseline: 0, step: Double(Float(0.05)), minimum: -12, maximum: 12)
        XCTAssertTrue(floatStep.accepts([12]))
        XCTAssertFalse(floatStep.accepts([0.025]))
    }

    func testParametricValidationEnforcesAllRangesStepsAndFilterMask() throws {
        let info = EqualizerFixtures.parametric
        let curve = try XCTUnwrap(EqualizerCurve.neutral(for: EqualizerFixtures.device(), kind: .parametric))
        XCTAssertTrue(curve.isValid)
        guard case .parametric(_, let bands) = curve else { return XCTFail("Expected parametric curve") }
        XCTAssertEqual(bands.count, info.count)
        XCTAssertEqual(info.filters, [.lowShelf, .peaking, .highShelf])
        for value in [-1, 11, .nan, .infinity] as [Double] {
            var invalid = bands
            invalid[0].q = value
            XCTAssertFalse(info.accepts(invalid))
        }
        for value in [0, 20001, .nan, .infinity] as [Double] {
            var invalid = bands
            invalid[0].frequency = value
            XCTAssertFalse(info.accepts(invalid))
        }
        for value in [-13, 0.1, .nan, .infinity] as [Double] {
            var invalid = bands
            invalid[0].gain = value
            XCTAssertFalse(info.accepts(invalid))
        }
        var invalid = bands
        invalid[0].filter = .notch
        XCTAssertFalse(info.accepts(invalid))
        XCTAssertFalse(info.accepts(Array(bands.dropLast())))
        XCTAssertEqual(EqualizerFilter.allCases.map(\.rawValue), [Int(HSC_EQ_FILTER_LOW_SHELF.rawValue), Int(HSC_EQ_FILTER_LOW_PASS.rawValue),
            Int(HSC_EQ_FILTER_PEAKING.rawValue), Int(HSC_EQ_FILTER_HIGH_PASS.rawValue), Int(HSC_EQ_FILTER_HIGH_SHELF.rawValue), Int(HSC_EQ_FILTER_NOTCH.rawValue)])
    }

    func testInvalidParametricMetadataCannotConstructNeutralCurves() {
        for mask in [0, -1, 1 << 30] {
            let info = ParametricEqualizerInfo(count: 3, baseline: 0, step: 1, minimum: -12, maximum: 12,
                                               qMinimum: 1, qMaximum: 1, frequencyMinimum: 20, frequencyMaximum: 20000, filterMask: mask)
            XCTAssertFalse(info.isValid)
        }
        var device = EqualizerFixtures.device()
        device.parametricEqualizerInfo = .failure(.init(operation: .equalizer, kind: .native(-2)))
        XCTAssertNil(EqualizerCurve.neutral(for: device, kind: .parametric))
    }
}

@MainActor final class EqualizerSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!
    private var store: EqualizerCurveStore!
    private var model: EqualizerSettingsModel!

    override func setUp() async throws {
        domain = "EqualizerTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        store = EqualizerCurveStore(defaults: defaults)
        model = EqualizerSettingsModel(store: store)
        model.update(devices: [EqualizerFixtures.device()], isFresh: true, testProfile: 0)
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: domain) }

    func testStorageRoundTripsKindsAndModelsWithoutPersistingAttachmentIdentity() throws {
        let device = EqualizerFixtures.device()
        let peq = try XCTUnwrap(EqualizerCurve.neutral(for: device, kind: .parametric))
        XCTAssertTrue(store.save(EqualizerFixtures.curve, usbID: device.usbID, testProfile: 0))
        XCTAssertTrue(store.save(peq, usbID: device.usbID, testProfile: 0))
        let reloaded = EqualizerCurveStore(defaults: defaults)
        XCTAssertEqual(reloaded.load(usbID: device.usbID, kind: .graphic, testProfile: 0), EqualizerFixtures.curve)
        XCTAssertEqual(reloaded.load(usbID: device.usbID, kind: .parametric, testProfile: 0), peq)
        XCTAssertNil(reloaded.load(usbID: .init(vendor: 1, product: 3), kind: .graphic, testProfile: 0))
        model.update(devices: [EqualizerFixtures.device(attachment: 999)], isFresh: true, testProfile: 0)
        XCTAssertEqual(model.draft, EqualizerFixtures.curve)
        let data = try XCTUnwrap(defaults.data(forKey: AppDefaults.equalizerCurvesKey))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("attachment"))
        XCTAssertFalse(store.save(EqualizerFixtures.curve, usbID: device.usbID, testProfile: 7))
        XCTAssertNil(reloaded.load(usbID: device.usbID, kind: .graphic, testProfile: 7))
        XCTAssertTrue(store.save(EqualizerFixtures.curve, usbID: .testDevice, testProfile: 7))
        XCTAssertNil(reloaded.load(usbID: .testDevice, kind: .graphic, testProfile: 6))
        XCTAssertNil(reloaded.load(usbID: .testDevice, kind: .graphic, testProfile: 0))
    }

    func testCorruptFutureAndNonfiniteStorageFailsClosed() throws {
        defaults.set(Data("broken".utf8), forKey: AppDefaults.equalizerCurvesKey)
        XCTAssertNil(store.load(usbID: EqualizerFixtures.usbID, kind: .graphic, testProfile: 0))
        let future = Data("{\"version\":2,\"differentSchema\":{}}".utf8)
        defaults.set(future, forKey: AppDefaults.equalizerCurvesKey)
        XCTAssertFalse(store.save(EqualizerFixtures.curve, usbID: EqualizerFixtures.usbID, testProfile: 0))
        XCTAssertEqual(defaults.data(forKey: AppDefaults.equalizerCurvesKey), future)
        XCTAssertFalse(store.save(.graphic(EqualizerFixtures.graphic, [.nan, 0, 0]), usbID: EqualizerFixtures.usbID, testProfile: 0))
    }

    func testSettingsBindingsSaveResetAndPresetCopyNeverSendCommands() throws {
        var calls = 0
        model.onApply = { _, _, _ in calls += 1 }
        let view = EqualizerSettingsView(model: model)
        XCTAssertNotNil(model.draft)
        view.graphicBinding(0).wrappedValue = 2.5
        model.saveDraft()
        XCTAssertEqual(store.load(usbID: EqualizerFixtures.usbID, kind: .graphic, testProfile: 0), model.draft)
        model.resetToNeutral()
        model.copyPreset(.init(index: 1, name: "Bass", bands: .success([3, 0, 0])))
        XCTAssertEqual(view.graphicBinding(0).wrappedValue, 3)
        model.copyPreset(.init(index: 2, name: "Wrong layout", bands: .success([6])))
        XCTAssertEqual(view.graphicBinding(0).wrappedValue, 3)
        model.kind = .parametric
        view.parametricBinding(0, \.frequency).wrappedValue = 100
        view.parametricBinding(0, \.gain).wrappedValue = 1.5
        view.parametricBinding(0, \.q).wrappedValue = 2
        view.filterBinding(0).wrappedValue = .lowShelf
        model.saveDraft()
        XCTAssertTrue(try XCTUnwrap(model.draft).isValid)
        model.copyPreset(.init(index: 0, name: "Flat", bands: .success([0, 0, 0])))
        XCTAssertEqual(view.parametricBinding(0, \.gain).wrappedValue, 1.5)
        XCTAssertEqual(calls, 0)
    }

    func testInvalidDraftStaysEditableButCannotBeAppliedOrSaved() throws {
        var calls = 0
        model.onApply = { _, _, _ in calls += 1 }
        let view = EqualizerSettingsView(model: model)
        view.graphicBinding(0).wrappedValue = 0.1
        XCTAssertFalse(try XCTUnwrap(model.draft).isValid)
        XCTAssertFalse(model.canApplyDraft)
        model.saveDraft()
        model.applyDraft()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(store.load(usbID: EqualizerFixtures.usbID, kind: .graphic, testProfile: 0))
        view.graphicBinding(0).wrappedValue = 0.5
        XCTAssertTrue(model.canApplyDraft)
        view.graphicBinding(0).wrappedValue = .nan
        XCTAssertEqual(view.sliderBinding(0, info: EqualizerFixtures.graphic).wrappedValue, 0)
        XCTAssertFalse(model.canApplyDraft)
        view.graphicBinding(0).wrappedValue = 99
        XCTAssertEqual(view.sliderBinding(0, info: EqualizerFixtures.graphic).wrappedValue, 12)
        XCTAssertEqual(view.graphicBinding(0).wrappedValue, 99) // Display safety must not repair the draft silently.
    }

    func testOnlySuccessfulExplicitApplySavesAndReplacesPresetSelection() throws {
        let target = try XCTUnwrap(model.selectedDevice?.target)
        model.record(.preset(1), on: target, generation: model.generation)
        model.setDraft(EqualizerFixtures.curve)
        var complete: ((Result<Void, HeadsetFailure>) -> Void)?
        var calls = 0
        model.onApply = { curve, receivedTarget, callback in
            calls += 1
            XCTAssertEqual(curve, EqualizerFixtures.curve)
            XCTAssertEqual(receivedTarget, target)
            complete = callback
        }
        model.applyDraft()
        model.applyDraft() // No duplicate write while the first is pending.
        XCTAssertEqual(calls, 1)
        complete?(.failure(.init(operation: .equalizer, kind: .native(-5))))
        XCTAssertEqual(model.draft, EqualizerFixtures.curve)
        XCTAssertEqual(model.lastApplied[target], .preset(1))
        XCTAssertTrue(model.message?.contains("-5") == true)
        XCTAssertNil(store.load(usbID: EqualizerFixtures.usbID, kind: .graphic, testProfile: 0))
        model.applyDraft()
        complete?(.success(()))
        XCTAssertEqual(model.lastApplied[target], .curve(EqualizerFixtures.curve))
        model.record(.preset(0), on: target, generation: model.generation)
        XCTAssertEqual(model.lastApplied[target], .preset(0))
        XCTAssertEqual(store.load(usbID: EqualizerFixtures.usbID, kind: .graphic, testProfile: 0), EqualizerFixtures.curve)
    }

    func testUnavailableMetadataNeverInitializesDeviceAndPreservesNativeError() {
        var device = EqualizerFixtures.device()
        let error = HeadsetFailure(operation: .equalizer, kind: .native(-2))
        device.equalizerInfo = .failure(error)
        device.parametricEqualizerInfo = .failure(error)
        var calls = 0
        model.onApply = { _, _, _ in calls += 1 }
        model.update(devices: [device], isFresh: true, testProfile: 0)
        model.resetToNeutral()
        model.applyDraft()
        XCTAssertNil(model.draft)
        XCTAssertFalse(model.canApplyDraft)
        XCTAssertTrue(model.metadataMessage?.contains("-2") == true)
        XCTAssertTrue(device.failures.isEmpty)
        XCTAssertEqual(calls, 0)
    }

    func testChangedLayoutRequiresExplicitResetAndDoesNotOverwriteSavedCurve() throws {
        store.save(EqualizerFixtures.curve, usbID: EqualizerFixtures.usbID, testProfile: 0)
        var device = EqualizerFixtures.device()
        device.equalizerInfo = .success(.init(count: 4, baseline: 0, step: 1, minimum: -6, maximum: 6))
        model.update(devices: [device], isFresh: true, testProfile: 0)
        XCTAssertNil(model.draft)
        XCTAssertNotNil(model.metadataMessage)
        XCTAssertFalse(model.canApplyDraft)
        XCTAssertEqual(store.load(usbID: device.usbID, kind: .graphic, testProfile: 0), EqualizerFixtures.curve)
        model.resetToNeutral()
        XCTAssertTrue(try XCTUnwrap(model.draft).isCompatible(with: device))
        XCTAssertTrue(model.canApplyDraft)
    }

    func testStaleAmbiguousReplacedAndCrossProfileTargetsCannotApply() throws {
        let oldTarget = try XCTUnwrap(model.selectedDevice?.target)
        var calls = 0
        model.onApply = { _, _, _ in calls += 1 }
        model.invalidate()
        model.apply(EqualizerFixtures.curve, to: oldTarget)
        var ambiguous = EqualizerFixtures.device()
        ambiguous.target = nil
        model.update(devices: [ambiguous], isFresh: true, testProfile: 0)
        model.apply(EqualizerFixtures.curve, to: oldTarget)
        model.update(devices: [EqualizerFixtures.device(attachment: 22)], isFresh: true, testProfile: 0)
        model.apply(EqualizerFixtures.curve, to: oldTarget)
        model.update(devices: [EqualizerFixtures.device()], isFresh: true, testProfile: 7)
        model.apply(EqualizerFixtures.curve, to: oldTarget)
        XCTAssertEqual(calls, 0)
    }

    func testLateSuccessAfterInvalidationCannotRestoreMarkerOrSaveCurve() throws {
        var complete: ((Result<Void, HeadsetFailure>) -> Void)?
        model.setDraft(EqualizerFixtures.curve)
        model.onApply = { _, _, callback in complete = callback }
        model.applyDraft()
        model.invalidate()
        model.update(devices: [EqualizerFixtures.device()], isFresh: true, testProfile: 0)
        complete?(.success(()))
        XCTAssertTrue(model.lastApplied.isEmpty)
        XCTAssertNil(model.message)
        XCTAssertNil(store.load(usbID: EqualizerFixtures.usbID, kind: .graphic, testProfile: 0))
    }
}

final class NativeEqualizerTests: XCTestCase {
    func testInstalledNativeProfilesExposeLayoutsCopyPresetBandsAndApplyBothKinds() async {
        let done = expectation(description: "native equalizer transactions")
        HeadsetIOWorker.shared.enqueue {
            let service = HeadsetControlService()
            do {
                let device = try XCTUnwrap(service.fetchDevices(testProfile: 7).get().first)
                let graphic = try XCTUnwrap(device.equalizerInfo).get()
                let parametric = try XCTUnwrap(device.parametricEqualizerInfo).get()
                XCTAssertEqual(graphic.count, 10)
                XCTAssertEqual(graphic.step, 0.5)
                XCTAssertEqual(parametric.filters, [.lowShelf, .peaking, .highShelf])
                XCTAssertTrue(device.capabilities.contains("CAP_EQUALIZER"))
                XCTAssertTrue(device.capabilities.contains("CAP_PARAMETRIC_EQUALIZER"))
                let presets = try XCTUnwrap(device.equalizerPresets).get()
                XCTAssertEqual(try XCTUnwrap(presets.first?.bands).get(), Array(repeating: 0, count: 10))
                for kind in EqualizerKind.allCases {
                    let curve = try XCTUnwrap(EqualizerCurve.neutral(for: device, kind: kind))
                    XCTAssertTrue(service.perform(.customEqualizer(curve), on: .test(profile: 7), testProfile: 7).isSuccess)
                    XCTAssertEqual(service.perform(.customEqualizer(curve), on: .test(profile: 1), testProfile: 1).failureValue?.kind, .native(-5))
                    XCTAssertEqual(service.perform(.customEqualizer(curve), on: .test(profile: 7), testProfile: 0).failureValue?.kind, .targetUnavailable)
                }
                XCTAssertEqual(service.perform(.customEqualizer(EqualizerFixtures.curve), on: .test(profile: 7), testProfile: 7).failureValue?.kind, .equalizerLayoutChanged)
                let invalid = EqualizerCurve.graphic(graphic, Array(repeating: .nan, count: graphic.count))
                XCTAssertEqual(service.perform(.customEqualizer(invalid), on: .test(profile: 7), testProfile: 7).failureValue?.kind, .native(-6))
                let invalidPEQ = EqualizerCurve.parametric(parametric, [.init(frequency: 10, gain: 0, q: 1, filter: .notch)])
                XCTAssertEqual(service.perform(.customEqualizer(invalidPEQ), on: .test(profile: 7), testProfile: 7).failureValue?.kind, .native(-6))
                // Copied Swift values survive every transaction's native release.
                XCTAssertEqual(try XCTUnwrap(presets[1].bands).get().first, 6)
            } catch { XCTFail("Native EQ regression: \(error)") }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
    }
}

@MainActor final class EqualizerTrayTests: XCTestCase {
    func testTrayUsesSavedCurvesExactTargetsAndOneMenuForAllEQCapabilities() async throws {
        let defaultsName = "EqualizerTray.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let oldProfile = AppDefaults.standard.object(forKey: "testMode")
        defer {
            AppDefaults.standard.set(oldProfile, forKey: "testMode")
            defaults.removePersistentDomain(forName: defaultsName)
        }
        AppDefaults.standard.set(0, forKey: "testMode")
        let store = EqualizerCurveStore(defaults: defaults)
        let model = EqualizerSettingsModel(store: store)
        let a = EqualizerFixtures.device()
        let b = EqualizerFixtures.device(id: .init(vendor: 3, product: 4), attachment: 22)
        store.save(EqualizerFixtures.curve, usbID: b.usbID, testProfile: 0)
        let provider = RecordingHeadsetProvider()
        provider.devices = [a, b]
        let executor = ManualHeadsetExecutor()
        let controller = HeadsetController(provider: provider, executor: executor)
        let delegate = AppDelegate(headsetController: controller, equalizerSettings: model)
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        XCTAssertTrue(provider.commands.isEmpty)
        let menu = NSMenu()
        delegate.rebuildMenu(menu)
        let submenus = menu.items.filter { $0.title == NSLocalizedString("Equalizer", comment: "") }.compactMap(\.submenu)
        XCTAssertEqual(submenus.count, 2)
        let first = try XCTUnwrap(submenus.first)
        let second = try XCTUnwrap(submenus.last)
        let title = NSLocalizedString("Apply Saved Custom Curve", comment: "")
        XCTAssertNil(first.items.first { $0.title == title }?.action)
        let saved = try XCTUnwrap(second.items.first { $0.title == title })
        XCTAssertNotNil(saved.action)
        XCTAssertEqual((saved.representedObject as? HeadsetEqualizerMenuAction)?.target, b.target)
        XCTAssertEqual(second.items.compactMap { ($0.representedObject as? HeadsetMenuAction)?.value }, [0, 1])
        let edit = try XCTUnwrap(second.items.first { $0.title == NSLocalizedString("Edit Equalizer…", comment: "") })
        delegate.editEqualizer(edit)
        XCTAssertEqual(model.selectedUSBID, b.usbID)
        XCTAssertEqual(model.settingsTab, 3)
        XCTAssertTrue(executor.jobs.isEmpty)
        model.select(a.usbID) // Applying B's old item must not target the editor's A.
        delegate.applySavedEqualizer(saved)
        executor.runNext()
        await drainResults()
        XCTAssertEqual(provider.commands.map { $0.0 }, [.customEqualizer(EqualizerFixtures.curve)])
        XCTAssertEqual(provider.commands.first?.1, b.target)
        XCTAssertEqual(model.lastApplied[try XCTUnwrap(b.target)], .curve(EqualizerFixtures.curve))
        executor.runNext() // Read metadata after the successful command.
        await drainResults()
        delegate.rebuildMenu(menu)
        XCTAssertTrue(menu.items.compactMap(\.submenu).flatMap(\.items).contains {
            $0.title.contains(NSLocalizedString("Last applied by this app: %@", comment: "").components(separatedBy: "%@")[0])
        })
        controller.invalidateSnapshot()
        delegate.applySavedEqualizer(saved)
        XCTAssertTrue(executor.jobs.isEmpty)
        delegate.rebuildMenu(menu)
        XCTAssertTrue(menu.items.compactMap(\.submenu).flatMap(\.items).filter { $0.title == title }.allSatisfy { $0.action == nil })
        XCTAssertTrue(model.lastApplied.isEmpty)
        provider.devices = [a, EqualizerFixtures.device(id: b.usbID, attachment: 33)]
        delegate.updateStatusItem()
        executor.runNext()
        await drainResults()
        delegate.applySavedEqualizer(saved)
        XCTAssertTrue(executor.jobs.isEmpty)
        XCTAssertEqual(provider.commands.count, 1)
        delegate.stop()
        executor.finishStop()
        await drainResults()
    }

    private func drainResults() async {
        await withCheckedContinuation { continuation in HeadsetMainRunLoop.perform { continuation.resume() } }
    }
}
