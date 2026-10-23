import Foundation

nonisolated enum EqualizerKind: String, CaseIterable, Codable, Sendable {
    case graphic, parametric

    var title: String {
        switch self {
        case .graphic: return NSLocalizedString("Graphic", comment: "Equalizer kind")
        case .parametric: return NSLocalizedString("Parametric", comment: "Equalizer kind")
        }
    }
}

// Store native metadata with each curve as its compatibility signature. No
// frequency layout, units or device identity are inferred from a model name.
nonisolated struct GraphicEqualizerInfo: Codable, Equatable, Sendable {
    let count: Int
    let baseline: Double
    let step: Double
    let minimum: Double
    let maximum: Double

    var isValid: Bool {
        AppDefaults.equalizerBandCountRange.contains(count)
            && [baseline, step, minimum, maximum].allSatisfy { $0.isFinite && Float($0).isFinite }
            && minimum < maximum && step > 0 && step <= maximum - minimum
            && (minimum...maximum).contains(baseline)
    }

    func accepts(_ bands: [Double]) -> Bool {
        isValid && bands.count == count && bands.allSatisfy {
            EqualizerCurve.validGain($0, baseline: baseline, step: step, minimum: minimum, maximum: maximum)
        }
    }
}

nonisolated struct ParametricEqualizerInfo: Codable, Equatable, Sendable {
    let count: Int
    let baseline: Double
    let step: Double
    let minimum: Double
    let maximum: Double
    let qMinimum: Double
    let qMaximum: Double
    let frequencyMinimum: Double
    let frequencyMaximum: Double
    let filterMask: Int

    var filters: [EqualizerFilter] { EqualizerFilter.allCases.filter { filterMask & (1 << $0.rawValue) != 0 } }
    var isValid: Bool {
        AppDefaults.equalizerBandCountRange.contains(count)
            && [baseline, step, minimum, maximum, qMinimum, qMaximum, frequencyMinimum, frequencyMaximum].allSatisfy { $0.isFinite && Float($0).isFinite }
            && minimum < maximum && step > 0 && step <= maximum - minimum
            && (minimum...maximum).contains(baseline)
            && qMinimum > 0 && qMinimum <= qMaximum
            && frequencyMinimum > 0 && frequencyMinimum < frequencyMaximum
            && filterMask > 0 && !filters.isEmpty
    }

    func accepts(_ bands: [ParametricEqualizerBand]) -> Bool {
        isValid && bands.count == count && bands.allSatisfy {
            EqualizerCurve.validGain($0.gain, baseline: baseline, step: step, minimum: minimum, maximum: maximum)
                && $0.frequency.isFinite && (frequencyMinimum...frequencyMaximum).contains($0.frequency)
                && $0.q.isFinite && (qMinimum...qMaximum).contains($0.q)
                && filters.contains($0.filter)
        }
    }
}

// These values mirror hsc_eq_filter_type_t, not the supported-filter bitmask.
nonisolated enum EqualizerFilter: Int, CaseIterable, Codable, Sendable {
    case lowShelf = 0, lowPass, peaking, highPass, highShelf, notch

    var title: String {
        switch self {
        case .lowShelf: return NSLocalizedString("Low shelf", comment: "EQ filter")
        case .lowPass: return NSLocalizedString("Low pass", comment: "EQ filter")
        case .peaking: return NSLocalizedString("Peaking", comment: "EQ filter")
        case .highPass: return NSLocalizedString("High pass", comment: "EQ filter")
        case .highShelf: return NSLocalizedString("High shelf", comment: "EQ filter")
        case .notch: return NSLocalizedString("Notch", comment: "EQ filter")
        }
    }
}

nonisolated struct ParametricEqualizerBand: Codable, Equatable, Sendable {
    var frequency: Double
    var gain: Double
    var q: Double
    var filter: EqualizerFilter
}

nonisolated enum EqualizerCurve: Codable, Equatable, Sendable {
    case graphic(GraphicEqualizerInfo, [Double])
    case parametric(ParametricEqualizerInfo, [ParametricEqualizerBand])

    var kind: EqualizerKind {
        switch self {
        case .graphic: return .graphic
        case .parametric: return .parametric
        }
    }

    var isValid: Bool {
        switch self {
        case .graphic(let info, let bands): return info.accepts(bands)
        case .parametric(let info, let bands): return info.accepts(bands)
        }
    }

    func isCompatible(with device: HeadsetDevice) -> Bool {
        isValid && matchesLayout(of: device)
    }

    func matchesLayout(of device: HeadsetDevice) -> Bool {
        switch self {
        case .graphic(let info, _):
            guard device.capabilities.contains("CAP_EQUALIZER"), case .success(let current) = device.equalizerInfo else { return false }
            return info == current && current.isValid
        case .parametric(let info, _):
            guard device.capabilities.contains("CAP_PARAMETRIC_EQUALIZER"), case .success(let current) = device.parametricEqualizerInfo else { return false }
            return info == current && current.isValid
        }
    }

    static func validGain(_ value: Double, baseline: Double, step: Double, minimum: Double, maximum: Double) -> Bool {
        guard value.isFinite, Float(value).isFinite, (minimum...maximum).contains(value) else { return false }
        let increments = (value - baseline) / step
        // Metadata steps originate as C floats (e.g. 0.05); allow their rounding
        // error, but never silently clamp or quantize an invalid saved value.
        return increments.isFinite && abs(increments - increments.rounded()) < 0.0001
    }

    static func neutral(for device: HeadsetDevice, kind: EqualizerKind) -> Self? {
        switch kind {
        case .graphic:
            guard case .success(let info) = device.equalizerInfo, info.isValid else { return nil }
            return .graphic(info, Array(repeating: info.baseline, count: info.count))
        case .parametric:
            guard case .success(let info) = device.parametricEqualizerInfo, info.isValid,
                  info.filters.contains(.peaking) else { return nil }
            // This is an explicitly new neutral curve, not a device observation.
            let bands = (0..<info.count).map { index in
                let fraction = info.count == 1 ? 0.5 : Double(index) / Double(info.count - 1)
                let frequency = exp(log(info.frequencyMinimum) + fraction * log(info.frequencyMaximum / info.frequencyMinimum))
                return ParametricEqualizerBand(frequency: min(info.frequencyMaximum, max(info.frequencyMinimum, frequency.rounded())),
                                              gain: info.baseline, q: min(info.qMaximum, max(info.qMinimum, 1)), filter: .peaking)
            }
            return .parametric(info, bands)
        }
    }
}

@MainActor final class EqualizerCurveStore {
    private struct Header: Decodable { let version: Int }
    private struct Archive: Codable {
        let version: Int
        var curves: [String: EqualizerCurve]
    }

    private let defaults: UserDefaults
    init(defaults: UserDefaults = AppDefaults.standard) { self.defaults = defaults }

    static func key(usbID: HeadsetUSBID, kind: EqualizerKind, testProfile: Int) -> String {
        // A registry attachment ID must never become persistent identity. Test
        // profiles cannot inherit either physical settings or another profile.
        let namespace = usbID == .testDevice ? "test-\(testProfile)" : "usb"
        return String(format: "%@-%04x-%04x-%@", namespace, usbID.vendor, usbID.product, kind.rawValue)
    }

    func load(usbID: HeadsetUSBID, kind: EqualizerKind, testProfile: Int) -> EqualizerCurve? {
        guard AppDefaults.isSupportedTestProfile(testProfile), (usbID == .testDevice) == (testProfile > 0),
              let archive = read(), archive.version == 1,
              let curve = archive.curves[Self.key(usbID: usbID, kind: kind, testProfile: testProfile)],
              curve.kind == kind, curve.isValid else { return nil }
        return curve
    }

    @discardableResult func save(_ curve: EqualizerCurve, usbID: HeadsetUSBID, testProfile: Int) -> Bool {
        guard curve.isValid, AppDefaults.isSupportedTestProfile(testProfile),
              (usbID == .testDevice) == (testProfile > 0) else { return false }
        // Do not overwrite a future schema with an older writer.
        if let data = defaults.data(forKey: AppDefaults.equalizerCurvesKey),
           let header = try? JSONDecoder().decode(Header.self, from: data), header.version != 1 { return false }
        var archive = read() ?? Archive(version: 1, curves: [:])
        archive.curves[Self.key(usbID: usbID, kind: curve.kind, testProfile: testProfile)] = curve
        guard let data = try? JSONEncoder().encode(archive) else { return false }
        defaults.set(data, forKey: AppDefaults.equalizerCurvesKey)
        return true
    }

    private func read() -> Archive? {
        guard let data = defaults.data(forKey: AppDefaults.equalizerCurvesKey), data.count < 1_048_576 else { return nil }
        return try? JSONDecoder().decode(Archive.self, from: data)
    }
}
