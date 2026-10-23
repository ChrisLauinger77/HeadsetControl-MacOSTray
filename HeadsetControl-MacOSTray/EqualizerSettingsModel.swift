import Foundation
import Observation

nonisolated enum EqualizerSelection: Equatable, Sendable {
    case preset(Int)
    case curve(EqualizerCurve)
}

@MainActor @Observable final class EqualizerSettingsModel {
    private(set) var devices: [HeadsetDevice] = []
    private(set) var isFresh = false
    private(set) var testProfile = 0
    private(set) var generation = 0
    private(set) var isApplying = false
    private(set) var message: String?
    private(set) var lastApplied: [HeadsetTarget: EqualizerSelection] = [:]
    var selectedUSBID: HeadsetUSBID?
    var kind: EqualizerKind = .graphic
    var settingsTab = 0
    @ObservationIgnored var onApply: ((EqualizerCurve, HeadsetTarget, @escaping (Result<Void, HeadsetFailure>) -> Void) -> Void)?
    @ObservationIgnored private let store: EqualizerCurveStore
    private var drafts: [String: EqualizerCurve] = [:]

    init(store: EqualizerCurveStore? = nil) { self.store = store ?? EqualizerCurveStore() }

    var selectedDevice: HeadsetDevice? { devices.first { $0.usbID == selectedUSBID } }
    var kinds: [EqualizerKind] {
        guard let device = selectedDevice else { return [] }
        return EqualizerKind.allCases.filter { device.capabilities.contains($0 == .graphic ? "CAP_EQUALIZER" : "CAP_PARAMETRIC_EQUALIZER") }
    }

    var draft: EqualizerCurve? {
        guard let device = selectedDevice else { return nil }
        if let curve = drafts[key(for: device, kind: kind)] ?? savedCurve(for: device, kind: kind) {
            return curve.matchesLayout(of: device) ? curve : nil
        }
        return EqualizerCurve.neutral(for: device, kind: kind)
    }

    var canApplyDraft: Bool {
        guard let device = selectedDevice, let curve = draft, let target = device.target else { return false }
        return canApply(curve, to: target)
    }

    var metadataMessage: String? {
        guard let device = selectedDevice else { return nil }
        let failure: HeadsetFailure?
        switch kind {
        case .graphic:
            if case .failure(let error) = device.equalizerInfo { failure = error } else { failure = nil }
        case .parametric:
            if case .failure(let error) = device.parametricEqualizerInfo { failure = error } else { failure = nil }
        }
        if let failure { return failure.message }
        if draft == nil {
            if drafts[key(for: device, kind: kind)] != nil || savedCurve(for: device, kind: kind) != nil {
                return NSLocalizedString("Equalizer layout changed. Reset or review the saved curve.", comment: "Incompatible equalizer curve")
            }
            return NSLocalizedString("Equalizer metadata unavailable. No settings have been sent to the device.", comment: "Missing EQ layout")
        }
        return nil
    }

    func update(devices: [HeadsetDevice], isFresh: Bool, testProfile: Int) {
        let supported = devices.filter { device in
            device.capabilities.contains("CAP_EQUALIZER") || device.capabilities.contains("CAP_PARAMETRIC_EQUALIZER")
        }
        let targets = Set(supported.compactMap(\.target))
        if self.testProfile != testProfile || Set(self.devices.compactMap(\.target)) != targets {
            generation += 1
            lastApplied = lastApplied.filter { targets.contains($0.key) && $0.key.accepts(testProfile: testProfile) }
        }
        self.testProfile = testProfile
        self.devices = supported
        self.isFresh = isFresh
        if !isFresh { invalidate() }
        if !supported.contains(where: { $0.usbID == selectedUSBID }) { selectedUSBID = supported.first?.usbID }
        if !kinds.contains(kind), let first = kinds.first { kind = first }
    }

    func invalidate() {
        isFresh = false
        generation += 1
        lastApplied.removeAll()
        message = nil
    }

    func select(_ usbID: HeadsetUSBID) {
        selectedUSBID = usbID
        if !kinds.contains(kind), let first = kinds.first { kind = first }
        settingsTab = 3
        message = nil
    }

    func setDraft(_ curve: EqualizerCurve) {
        guard let device = selectedDevice, curve.kind == kind else { return }
        drafts[key(for: device, kind: kind)] = curve
        message = nil
    }

    func resetToNeutral() {
        guard let device = selectedDevice, let curve = EqualizerCurve.neutral(for: device, kind: kind) else { return }
        setDraft(curve)
    }

    func copyPreset(_ preset: HeadsetEqualizerPreset) {
        guard kind == .graphic, let device = selectedDevice, case .success(let info) = device.equalizerInfo,
              case .success(let bands) = preset.bands, info.accepts(bands) else { return }
        setDraft(.graphic(info, bands))
    }

    func saveDraft() {
        guard let device = selectedDevice, let curve = draft, curve.isCompatible(with: device) else { return }
        message = store.save(curve, usbID: device.usbID, testProfile: testProfile)
            ? NSLocalizedString("Curve saved locally.", comment: "Saved equalizer")
            : NSLocalizedString("Could not save the equalizer curve.", comment: "Equalizer storage error")
    }

    func savedCurve(for device: HeadsetDevice, kind: EqualizerKind) -> EqualizerCurve? {
        store.load(usbID: device.usbID, kind: kind, testProfile: testProfile)
    }

    func canApply(_ curve: EqualizerCurve, to target: HeadsetTarget) -> Bool {
        isFresh && !isApplying && target.accepts(testProfile: testProfile)
            && devices.contains { $0.target == target && curve.isCompatible(with: $0) }
    }

    func applyDraft() {
        guard let curve = draft, let target = selectedDevice?.target else { return }
        apply(curve, to: target)
    }

    func apply(_ curve: EqualizerCurve, to target: HeadsetTarget) {
        guard canApply(curve, to: target), let device = devices.first(where: { $0.target == target }), let onApply else { return }
        let generation = self.generation
        let profile = testProfile
        isApplying = true
        message = nil
        onApply(curve, target) { [weak self] result in
            guard let self else { return }
            self.isApplying = false
            guard self.generation == generation, self.isFresh, self.testProfile == profile,
                  self.devices.contains(where: { $0.target == target }) else { return }
            switch result {
            case .success:
                self.record(.curve(curve), on: target, generation: generation)
                let saved = self.store.save(curve, usbID: device.usbID, testProfile: profile)
                self.message = saved ? NSLocalizedString("Curve applied and saved.", comment: "Applied equalizer")
                    : NSLocalizedString("Curve applied, but could not be saved locally.", comment: "Equalizer storage error after applying")
            case .failure(let error):
                if !error.isCancelled { self.message = error.message }
            }
        }
    }

    func record(_ selection: EqualizerSelection, on target: HeadsetTarget, generation: Int) {
        guard generation == self.generation, isFresh, target.accepts(testProfile: testProfile) else { return }
        lastApplied[target] = selection
    }

    private func key(for device: HeadsetDevice, kind: EqualizerKind) -> String {
        EqualizerCurveStore.key(usbID: device.usbID, kind: kind, testProfile: testProfile)
    }
}
