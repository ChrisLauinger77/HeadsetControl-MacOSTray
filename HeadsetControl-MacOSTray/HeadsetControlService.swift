import Foundation
import HeadsetControlCLib

nonisolated struct HeadsetCapability {
    let rawValue: hsc_capability_t

    static let sidetone = HeadsetCapability(rawValue: HSC_CAP_SIDETONE)
    static let batteryStatus = HeadsetCapability(rawValue: HSC_CAP_BATTERY_STATUS)
    static let notificationSound = HeadsetCapability(rawValue: HSC_CAP_NOTIFICATION_SOUND)
    static let lights = HeadsetCapability(rawValue: HSC_CAP_LIGHTS)
    static let inactiveTime = HeadsetCapability(rawValue: HSC_CAP_INACTIVE_TIME)
    static let chatmixStatus = HeadsetCapability(rawValue: HSC_CAP_CHATMIX_STATUS)
    static let voicePrompts = HeadsetCapability(rawValue: HSC_CAP_VOICE_PROMPTS)
    static let rotateToMute = HeadsetCapability(rawValue: HSC_CAP_ROTATE_TO_MUTE)
    static let equalizerPreset = HeadsetCapability(rawValue: HSC_CAP_EQUALIZER_PRESET)
    static let equalizer = HeadsetCapability(rawValue: HSC_CAP_EQUALIZER)
    static let parametricEqualizer = HeadsetCapability(rawValue: HSC_CAP_PARAMETRIC_EQUALIZER)
    static let microphoneMuteLedBrightness = HeadsetCapability(rawValue: HSC_CAP_MICROPHONE_MUTE_LED_BRIGHTNESS)
    static let microphoneVolume = HeadsetCapability(rawValue: HSC_CAP_MICROPHONE_VOLUME)
    static let volumeLimiter = HeadsetCapability(rawValue: HSC_CAP_VOLUME_LIMITER)
    static let bluetoothWhenPoweredOn = HeadsetCapability(rawValue: HSC_CAP_BT_WHEN_POWERED_ON)
    static let bluetoothCallVolume = HeadsetCapability(rawValue: HSC_CAP_BT_CALL_VOLUME)

    var legacyCapabilityString: String {
        switch rawValue {
        case HSC_CAP_SIDETONE: return "CAP_SIDETONE"
        case HSC_CAP_BATTERY_STATUS: return "CAP_BATTERY_STATUS"
        case HSC_CAP_NOTIFICATION_SOUND: return "CAP_NOTIFICATION_SOUND"
        case HSC_CAP_LIGHTS: return "CAP_LIGHTS"
        case HSC_CAP_INACTIVE_TIME: return "CAP_INACTIVE_TIME"
        case HSC_CAP_CHATMIX_STATUS: return "CAP_CHATMIX_STATUS"
        case HSC_CAP_VOICE_PROMPTS: return "CAP_VOICE_PROMPTS"
        case HSC_CAP_ROTATE_TO_MUTE: return "CAP_ROTATE_TO_MUTE"
        case HSC_CAP_EQUALIZER_PRESET: return "CAP_EQUALIZER_PRESET"
        case HSC_CAP_EQUALIZER: return "CAP_EQUALIZER"
        case HSC_CAP_PARAMETRIC_EQUALIZER: return "CAP_PARAMETRIC_EQUALIZER"
        case HSC_CAP_MICROPHONE_MUTE_LED_BRIGHTNESS: return "CAP_MICROPHONE_MUTE_LED_BRIGHTNESS"
        case HSC_CAP_MICROPHONE_VOLUME: return "CAP_MICROPHONE_VOLUME"
        case HSC_CAP_VOLUME_LIMITER: return "CAP_VOLUME_LIMITER"
        case HSC_CAP_BT_WHEN_POWERED_ON: return "CAP_BT_WHEN_POWERED_ON"
        case HSC_CAP_BT_CALL_VOLUME: return "CAP_BT_CALL_VOLUME"
        default: return ""
        }
    }

    static let menuCapabilities: [HeadsetCapability] = [
        .sidetone,
        .lights,
        .inactiveTime,
        .voicePrompts,
        .rotateToMute,
        .equalizerPreset
    ]
}

// All mutable state, including the injected adapter, belongs to one executor.
// Production adapters assert the shared HID thread at the transaction boundary.
nonisolated final class HeadsetControlService: HeadsetControlProviding, @unchecked Sendable {
    /// Version APIs do not initialize HID, but hsc_version lazily mutates a string.
    /// Keep even this metadata read on the existing native worker.
    static func nativeVersions(provenance: Data?) -> NativeDependencyVersions {
        precondition(HeadsetIOWorker.shared.isCurrentThread)
        return NativeDependencyVersions(
            headsetControl: hsc_version().flatMap { String(validatingCString: $0) },
            hidapi: hid_version_str().flatMap { String(validatingCString: $0) },
            provenance: provenance
        )
    }

    @MainActor static func requestNativeVersions(completion: @escaping @MainActor @Sendable (NativeDependencyVersions) -> Void) {
        HeadsetIOWorker.shared.enqueue {
            let result = bundledNativeVersions
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    // Loaded once off the main actor. Shutdown can discard the queued read without
    // leaking an async continuation; there is no wait, discovery or HID initialization.
    private static let bundledNativeVersions: NativeDependencyVersions = {
        let data = Bundle.main.url(forResource: "BuildProvenance", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        let result = nativeVersions(provenance: data)
        for diagnostic in result.diagnostics { NSLog("Native dependency versions: %@", diagnostic) }
        return result
    }()

    private let library: HeadsetLibraryAccess
    private let inventory: HeadsetUSBInventoryProviding
    private let checkExecutionContext: () -> Void
    private var inTransaction = false
    private var stopped = false

    convenience init() {
        self.init(library: NativeHeadsetLibrary(), inventory: HeadsetUSBInventory()) {
            precondition(HeadsetIOWorker.shared.isCurrentThread, "Native transactions require the HID worker")
        }
    }

    // Injection is for deterministic tests; a native adapter always uses the
    // production initializer and therefore the process-wide execution context.
    init(library: HeadsetLibraryAccess, inventory: HeadsetUSBInventoryProviding,
         checkExecutionContext: @escaping () -> Void = {}) {
        self.library = library
        self.inventory = inventory
        self.checkExecutionContext = checkExecutionContext
    }

    func fetchDevices(testProfile: Int) -> Result<[HeadsetDevice], HeadsetFailure> {
        withTransaction(testProfile: testProfile, operation: .discovery) {
            let before = testProfile > 0 ? nil : inventory.attachments()
            let connections: [HeadsetConnection]
            switch library.discover() {
            case .success(let value): connections = value
            case .failure(let error): return .failure(error)
            }
            let after = testProfile > 0 ? nil : inventory.attachments()
            return .success(connections.compactMap { connection in
                // The library adds its test device to physical discovery. Filter
                // BEFORE battery/chatmix calls so fake mode never queries hardware.
                guard (connection.usbID == .testDevice) == (testProfile > 0) else { return nil }
                var device = library.readDevice(connection)
                if testProfile > 0 {
                    device.target = .test(profile: testProfile)
                } else if let ids = before?[connection.usbID], ids.count == 1,
                          after?[connection.usbID] == ids,
                          connections.filter({ $0.usbID == connection.usbID }).count == 1 {
                    device.target = .physical(connection.usbID, attachmentID: ids[0])
                }
                return device
            })
        }
    }

    func perform(_ command: HeadsetCommand, on target: HeadsetTarget, testProfile: Int) -> Result<Void, HeadsetFailure> {
        guard AppDefaults.testProfileRange.contains(testProfile) else {
            return .failure(.init(operation: .command, kind: .invalidTestProfile(testProfile)))
        }
        guard target.accepts(testProfile: testProfile) else {
            return .failure(.init(operation: .command, kind: .targetUnavailable))
        }
        return withTransaction(testProfile: testProfile, operation: .command) {
            guard targetIsAttached(target) else {
                return .failure(.init(operation: .command, kind: .targetUnavailable))
            }
            let connections: [HeadsetConnection]
            switch library.discover() {
            case .success(let value): connections = value
            case .failure(let error): return .failure(error)
            }
            let usbID: HeadsetUSBID
            switch target {
            case .physical(let id, _): usbID = id
            case .test: usbID = .testDevice
            }
            let matches = connections.filter { $0.usbID == usbID }
            guard matches.count == 1, let connection = matches.first,
                  targetIsAttached(target) else {
                return .failure(.init(operation: .command, kind: .targetUnavailable))
            }
            // Exactly one selected handle; there is deliberately no broadcast loop.
            // The C API opens by VID/PID inside this call. Atomic binding across
            // a replacement AFTER our last check requires a dependency path API.
            return library.perform(command, on: connection)
        }
    }

    func shutdown() {
        checkExecutionContext()
        guard !stopped else { return }
        precondition(!inTransaction, "Shutdown must follow the active transaction")
        stopped = true
        library.shutdown()
    }

    private func targetIsAttached(_ target: HeadsetTarget) -> Bool {
        switch target {
        case .test: return true
        case .physical(let id, let attachmentID):
            // The dependency selects by VID/PID, not by path or serial number.
            // Only a unique, unchanged USB attachment can be offered controls.
            return id != .testDevice && inventory.attachments()?[id] == [attachmentID]
        }
    }

    private func withTransaction<T>(testProfile: Int, operation: HeadsetOperation,
                                    _ body: () -> Result<T, HeadsetFailure>) -> Result<T, HeadsetFailure> {
        checkExecutionContext()
        guard AppDefaults.testProfileRange.contains(testProfile) else {
            return .failure(.init(operation: operation, kind: .invalidTestProfile(testProfile)))
        }
        guard !stopped else { return .failure(.init(operation: operation, kind: .stopped)) }
        guard !inTransaction else { return .failure(.init(operation: operation, kind: .reentrant)) }
        inTransaction = true
        defer {
            library.releaseDevices()
            try? library.configure(testProfile: 0)
            inTransaction = false
        }
        do { try library.configure(testProfile: testProfile) }
        catch { return .failure(error) }
        return body()
    }

}

nonisolated final class MockHeadsetControlService: HeadsetControlProviding, Sendable {
    private let deviceIndex: Int

    init(deviceIndex: Int) { self.deviceIndex = deviceIndex }

    func fetchDevices(testProfile: Int) -> Result<[HeadsetDevice], HeadsetFailure> {
        .success([HeadsetDevice(
            usbID: .testDevice, name: "Test Device \(deviceIndex)", vendor: "HeadsetControl", product: "Test Device",
            capabilities: HeadsetCapability.menuCapabilities.map { $0.legacyCapabilityString },
            battery: .success(.init(level: max(5, min(95, 10 * deviceIndex)), status: .available, timeToEmpty: 120)),
            chatmix: .success(50), target: .test(profile: testProfile)
        )])
    }

    func perform(_ command: HeadsetCommand, on target: HeadsetTarget, testProfile: Int) -> Result<Void, HeadsetFailure> {
        target == .test(profile: testProfile) && AppDefaults.testProfileRange.contains(testProfile) && testProfile > 0
            ? .success(()) : .failure(.init(operation: .command, kind: .targetUnavailable))
    }
    func shutdown() {}
}
