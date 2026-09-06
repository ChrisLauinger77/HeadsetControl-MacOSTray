import Foundation

// USB IDs identify a model, not a physical device. attachmentID is an IOKit
// connection identifier, never persisted or used to select identical devices.
nonisolated struct HeadsetUSBID: Hashable, Sendable {
    let vendor: UInt16
    let product: UInt16

    static let testDevice = HeadsetUSBID(vendor: 0xf00b, product: 0xa00c)
}

nonisolated enum HeadsetTarget: Hashable, Sendable {
    case physical(HeadsetUSBID, attachmentID: UInt64)
    case test(profile: Int)

    func accepts(testProfile: Int) -> Bool {
        switch self {
        case .physical: return testProfile == 0
        case .test(let profile): return profile > 0 && profile == testProfile
        }
    }
}

nonisolated enum HeadsetCommand: Equatable, Sendable {
    case sidetone(Int)
    case lights(Bool)
    case inactiveTime(Int)
    case voicePrompts(Bool)
    case rotateToMute(Bool)
    case equalizerPreset(Int)
}

// Only immutable value data crosses from the HID worker to the main actor.
nonisolated struct HeadsetDevice: Sendable {
    let usbID: HeadsetUSBID
    let name: String
    let vendor: String
    let product: String
    let capabilities: [String]
    var battery: Result<HeadsetBattery, HeadsetFailure>? = nil
    var chatmix: Result<Int, HeadsetFailure>? = nil
    var equalizerPresets: Result<[HeadsetEqualizerPreset], HeadsetFailure>? = nil
    var target: HeadsetTarget? = nil

    var failures: [HeadsetFailure] {
        var result: [HeadsetFailure] = []
        if case .failure(let error) = battery { result.append(error) }
        if case .failure(let error) = chatmix { result.append(error) }
        if case .failure(let error) = equalizerPresets { result.append(error) }
        return result
    }

    // AppKit owns the dictionary; all telemetry inside it keeps its typed result.
    var menuDictionary: [String: Any] {
        var result: [String: Any] = [
            "status": "success", "device": name, "vendor": vendor, "product": product,
            "vendor_id": String(format: "0x%04x", usbID.vendor),
            "product_id": String(format: "0x%04x", usbID.product),
            "capabilities": capabilities
        ]
        result["control_target"] = target
        result["battery"] = battery
        result["chatmix"] = chatmix
        result["equalizerPresets"] = equalizerPresets
        return result
    }
}

// Synchronous transaction boundary. Called only by the execution context,
// never from an AppKit callback. Fakes can block or reenter the coordinator.
nonisolated protocol HeadsetControlProviding: AnyObject, Sendable {
    nonisolated func fetchDevices(testProfile: Int) -> Result<[HeadsetDevice], HeadsetFailure>
    nonisolated func perform(_ command: HeadsetCommand, on target: HeadsetTarget, testProfile: Int) -> Result<Void, HeadsetFailure>
    nonisolated func shutdown()
}

nonisolated protocol HeadsetWorkExecuting: AnyObject, Sendable {
    nonisolated func enqueue(_ work: @escaping @Sendable () -> Void)
    nonisolated func stop(cleanup: @escaping @Sendable () -> Void, completion: @escaping @Sendable () -> Void)
}

// Stored on each individual control item, never inferred from the current menu.
struct HeadsetMenuAction {
    let target: HeadsetTarget?
    let value: Int
    var deviceName: String = ""
}
