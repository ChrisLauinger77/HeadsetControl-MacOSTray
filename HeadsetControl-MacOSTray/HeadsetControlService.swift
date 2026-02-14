import Foundation
import HeadsetControlCLib

protocol HeadsetControlProviding {
    func fetchDevices() -> [[String: Any]]
    func setSidetone(level: Int) -> Bool
    func setLights(enabled: Bool) -> Bool
    func setInactiveTime(minutes: Int) -> Bool
    func setVoicePrompts(enabled: Bool) -> Bool
    func setRotateToMute(enabled: Bool) -> Bool
    func setEqualizerPreset(index: Int) -> Bool
}

struct HeadsetCapability {
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
        .equalizerPreset,
        .equalizer
    ]
}

private func legacyBatteryStatusString(_ status: hsc_battery_status_t) -> String? {
    switch status {
    case HSC_BATTERY_AVAILABLE: return "BATTERY_AVAILABLE"
    case HSC_BATTERY_CHARGING: return "BATTERY_CHARGING"
    case HSC_BATTERY_UNAVAILABLE: return "BATTERY_UNAVAILABLE"
    default: return nil
    }
}

final class HeadsetControlService: HeadsetControlProviding {
    private let libraryLock = NSLock()

    func fetchDevices() -> [[String: Any]] {
        return withDiscoveredHeadsets { headsets in
            var devices: [[String: Any]] = []
            devices.reserveCapacity(headsets.count)

            for headset in headsets {
                var device: [String: Any] = [:]
                device["status"] = "success"
                device["device"] = stringFromC(hsc_get_name(headset))
                device["vendor"] = String(format: "0x%04x", hsc_get_vendor_id(headset))
                device["product"] = String(format: "0x%04x", hsc_get_product_id(headset))

                let capabilities = HeadsetCapability.menuCapabilities.compactMap { cap -> String? in
                    hsc_supports(headset, cap.rawValue) ? cap.legacyCapabilityString : nil
                }
                device["capabilities"] = capabilities

                if hsc_supports(headset, HeadsetCapability.batteryStatus.rawValue) {
                    var battery = hsc_battery_t()
                    let result = hsc_get_battery(headset, &battery)
                    if result == HSC_RESULT_OK {
                        var batteryInfo: [String: Any] = [
                            "level": Int(battery.level_percent)
                        ]
                        if let status = legacyBatteryStatusString(battery.status) {
                            batteryInfo["status"] = status
                        }
                        if battery.time_to_empty_min >= 0 {
                            batteryInfo["time_to_empty_min"] = Int(battery.time_to_empty_min)
                        }
                        device["battery"] = batteryInfo
                    }
                }

                if hsc_supports(headset, HeadsetCapability.chatmixStatus.rawValue) {
                    var chatmix = hsc_chatmix_t()
                    if hsc_get_chatmix(headset, &chatmix) == HSC_RESULT_OK {
                        device["chatmix"] = Int(chatmix.level)
                    }
                }

                devices.append(device)
            }

            return devices
        } ?? []
    }

    func setSidetone(level: Int) -> Bool {
        let clamped = max(0, min(128, level))
        return performOnHeadsets { headset in
            guard hsc_supports(headset, HeadsetCapability.sidetone.rawValue) else { return false }
            return hsc_set_sidetone(headset, UInt8(clamped), nil) == HSC_RESULT_OK
        }
    }

    func setLights(enabled: Bool) -> Bool {
        return performOnHeadsets { headset in
            guard hsc_supports(headset, HeadsetCapability.lights.rawValue) else { return false }
            return hsc_set_lights(headset, enabled) == HSC_RESULT_OK
        }
    }

    func setInactiveTime(minutes: Int) -> Bool {
        let clamped = max(0, min(90, minutes))
        return performOnHeadsets { headset in
            guard hsc_supports(headset, HeadsetCapability.inactiveTime.rawValue) else { return false }
            return hsc_set_inactive_time(headset, UInt8(clamped), nil) == HSC_RESULT_OK
        }
    }

    func setVoicePrompts(enabled: Bool) -> Bool {
        return performOnHeadsets { headset in
            guard hsc_supports(headset, HeadsetCapability.voicePrompts.rawValue) else { return false }
            return hsc_set_voice_prompts(headset, enabled) == HSC_RESULT_OK
        }
    }

    func setRotateToMute(enabled: Bool) -> Bool {
        return performOnHeadsets { headset in
            guard hsc_supports(headset, HeadsetCapability.rotateToMute.rawValue) else { return false }
            return hsc_set_rotate_to_mute(headset, enabled) == HSC_RESULT_OK
        }
    }

    func setEqualizerPreset(index: Int) -> Bool {
        let clamped = max(0, min(255, index))
        return performOnHeadsets { headset in
            guard hsc_supports(headset, HeadsetCapability.equalizerPreset.rawValue) else { return false }
            return hsc_set_equalizer_preset(headset, UInt8(clamped)) == HSC_RESULT_OK
        }
    }

    private func performOnHeadsets(_ action: (hsc_headset_t) -> Bool) -> Bool {
        return withDiscoveredHeadsets { headsets in
            var success = false
            for headset in headsets {
                if action(headset) {
                    success = true
                }
            }
            return success
        } ?? false
    }

    private func withDiscoveredHeadsets<T>(_ body: ([hsc_headset_t]) -> T) -> T? {
        libraryLock.lock()
        defer { libraryLock.unlock() }

        var headsetsPtr: UnsafeMutablePointer<hsc_headset_t?>?
        let count = hsc_discover(&headsetsPtr)
        guard count > 0, let headsetsPtr else { return nil }
        defer { hsc_free_headsets(headsetsPtr, count) }

        let buffer = UnsafeBufferPointer(start: headsetsPtr, count: Int(count))
        let headsets = buffer.compactMap { $0 }
        return body(headsets)
    }

    private func stringFromC(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(cString: pointer)
    }
}

final class MockHeadsetControlService: HeadsetControlProviding {
    private let deviceIndex: Int

    init(deviceIndex: Int) {
        self.deviceIndex = deviceIndex
    }

    func fetchDevices() -> [[String: Any]] {
        let deviceName = "Test Device \(deviceIndex)"
        let batteryLevel = max(5, min(95, 10 * deviceIndex))
        return [[
            "status": "success",
            "device": deviceName,
            "vendor": "0xF00B",
            "product": "0xA00C",
            "capabilities": HeadsetCapability.menuCapabilities.map { $0.legacyCapabilityString },
            "battery": [
                "status": "BATTERY_AVAILABLE",
                "level": batteryLevel,
                "time_to_empty_min": 120
            ],
            "chatmix": 50
        ]]
    }

    func setSidetone(level: Int) -> Bool { true }
    func setLights(enabled: Bool) -> Bool { true }
    func setInactiveTime(minutes: Int) -> Bool { true }
    func setVoicePrompts(enabled: Bool) -> Bool { true }
    func setRotateToMute(enabled: Bool) -> Bool { true }
    func setEqualizerPreset(index: Int) -> Bool { true }
}
