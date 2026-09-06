import Foundation

nonisolated enum HeadsetOperation: String, Sendable {
    case discovery = "Discovery"
    case battery = "Battery"
    case chatmix = "Chatmix"
    case equalizer = "Equalizer Preset"
    case command = "Control"
}

nonisolated struct HeadsetFailure: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case native(Int32)
        case batteryStatus(Int)
        case invalidResponse(String)
        case invalidTestProfile(Int)
        case targetUnavailable
        case unsupportedPreset(Int)
        case stopped
        case reentrant
        case cancelled
    }

    let operation: HeadsetOperation
    let kind: Kind
    var isCancelled: Bool { kind == .cancelled }

    var message: String {
        let reason: String
        switch kind {
        case .native(let code):
            let key: String
            switch code {
            case -2: key = "Not supported"
            case -3: key = "Device offline"
            case -4: key = "Timed out"
            case -5: key = "HID communication failed"
            case -6: key = "Invalid parameter"
            default: key = "Native operation failed"
            }
            reason = "\(NSLocalizedString(key, comment: "Native error")) (\(code))"
        case .batteryStatus(let status):
            let key = status == 3 ? "HID communication failed" : "Timed out"
            reason = "\(NSLocalizedString(key, comment: "Battery error status")) (\(status))"
        case .invalidResponse: reason = NSLocalizedString("Invalid device response", comment: "Invalid telemetry")
        case .invalidTestProfile: reason = NSLocalizedString("Invalid test profile", comment: "Invalid test mode")
        case .targetUnavailable: reason = NSLocalizedString("Device connection changed or is ambiguous", comment: "Unsafe command target")
        case .unsupportedPreset: reason = NSLocalizedString("Preset is not supported", comment: "Invalid preset index")
        case .stopped, .cancelled: reason = NSLocalizedString("Operation cancelled", comment: "Stopped operation")
        case .reentrant: reason = NSLocalizedString("Operation already in progress", comment: "Nested native operation")
        }
        return "\(NSLocalizedString(operation.rawValue, comment: "Failed operation")): \(reason)"
    }

    static func result(code: Int32, operation: HeadsetOperation) -> Result<Void, HeadsetFailure> {
        code == 0 ? .success(()) : .failure(.init(operation: operation, kind: .native(code)))
    }
}

nonisolated struct HeadsetBattery: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case available, charging, unavailable, unknown(Int)
    }

    let level: Int
    let status: Status
    var timeToEmpty: Int? = nil

    var percentage: Int? {
        guard status == .available || status == .charging, (0...100).contains(level) else { return nil }
        return level
    }

    var chargeText: String? {
        if let percentage { return (status == .charging ? "⚡︎ " : "") + "\(percentage)%" }
        return status == .charging ? "⚡︎" : nil
    }

    var statusText: String {
        switch status {
        case .available: return NSLocalizedString("Invalid device response", comment: "Invalid battery level")
        case .charging: return NSLocalizedString("Charging", comment: "Charging without a percentage")
        case .unavailable: return NSLocalizedString("Unavailable", comment: "Unavailable battery")
        case .unknown: return NSLocalizedString("Unknown", comment: "Unknown battery state")
        }
    }

    // headsetcontrol 4.1.0's C wrapper casts lib/device.hpp's enum directly:
    // unavailable=0, charging=1, available=2, HID error=3, timeout=4.
    // Its public C header declares DIFFERENT values. Never interpret raw 0 as
    // an available measurement. Native profile tests guard this ABI assumption.
    static func decode(level: Int, rawStatus: Int, timeToEmpty: Int? = nil) -> Result<Self, HeadsetFailure> {
        let status: Status
        switch rawStatus {
        case 0: status = .unavailable
        case 1: status = .charging
        case 2: status = .available
        case 3: return .failure(.init(operation: .battery, kind: .batteryStatus(3)))
        case 4: return .failure(.init(operation: .battery, kind: .batteryStatus(4)))
        default: status = .unknown(rawStatus)
        }
        if (status == .available && !(0...100).contains(level)) || (status == .charging && level > 100) {
            return .failure(.init(operation: .battery, kind: .invalidResponse("Battery level \(level)")))
        }
        return .success(Self(level: level, status: status, timeToEmpty: timeToEmpty.flatMap { $0 > 0 ? $0 : nil }))
    }
}

nonisolated struct HeadsetEqualizerPreset: Equatable, Sendable {
    let index: Int
    let name: String?

    static func read(count: Int, nameAt: (Int) -> String?) -> Result<[Self], HeadsetFailure> {
        guard (0...255).contains(count) else {
            return .failure(.init(operation: .equalizer, kind: .invalidResponse("Preset count \(count)")))
        }
        // Count zero gives no supported indices; names alone must not invent any.
        return .success((0..<count).map { index in
            let name = nameAt(index)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self(index: index, name: name?.isEmpty == false ? name : nil)
        })
    }
}
