import Foundation
import HeadsetControlCLib

// This is the only owner of native handles. Configure, discovery, I/O, freeing
// handles and HID teardown all run on HeadsetIOWorker.shared's fixed thread.
nonisolated final class NativeHeadsetLibrary: HeadsetLibraryAccess {
    private var headsetsPointer: UnsafeMutablePointer<hsc_headset_t?>?
    private var count: Int32 = 0
    private var handles: [hsc_headset_t] = []
    private var used = false

    func configure(testProfile: Int) throws(HeadsetFailure) {
        assertWorker()
        guard AppDefaults.testProfileRange.contains(testProfile) else {
            throw HeadsetFailure(operation: .discovery, kind: .invalidTestProfile(testProfile))
        }
        used = true
        let profile = Int32(testProfile)
        hsc_set_test_profile(profile)
        hsc_enable_test_device(profile > 0)
    }

    func discover() -> Result<[HeadsetConnection], HeadsetFailure> {
        assertWorker()
        precondition(headsetsPointer == nil && handles.isEmpty)
        count = hsc_discover(&headsetsPointer)
        guard count >= 0 else { return .failure(.init(operation: .discovery, kind: .native(count))) }
        guard count > 0 else { return .success([]) }
        guard let headsetsPointer else {
            return .failure(.init(operation: .discovery, kind: .invalidResponse("Missing discovery array")))
        }
        handles = UnsafeBufferPointer(start: headsetsPointer, count: Int(count)).compactMap { $0 }
        guard handles.count == Int(count) else {
            return .failure(.init(operation: .discovery, kind: .invalidResponse("Null headset handle")))
        }
        return .success(handles.enumerated().map { index, handle in
            HeadsetConnection(index: index, usbID: HeadsetUSBID(vendor: hsc_get_vendor_id(handle), product: hsc_get_product_id(handle)))
        })
    }

    func readDevice(_ connection: HeadsetConnection) -> HeadsetDevice {
        assertWorker()
        let handle = handles[connection.index]
        var batteryResult: Result<HeadsetBattery, HeadsetFailure>?
        var chatmixResult: Result<Int, HeadsetFailure>?
        var sidetoneResult: Result<HeadsetSidetone, HeadsetFailure>?
        var microphoneMuted: Result<Bool, HeadsetFailure>?
        var microphoneAttached: Result<Bool, HeadsetFailure>?
        var equalizerPresets: Result<[HeadsetEqualizerPreset], HeadsetFailure>?
        if hsc_supports(handle, HSC_CAP_BATTERY_STATUS) {
            var battery = hsc_battery_t()
            let code = hsc_get_battery(handle, &battery)
            if code == HSC_RESULT_OK {
                batteryResult = HeadsetBattery.decode(level: Int(battery.level_percent), rawStatus: Int(battery.status.rawValue),
                                                      timeToEmpty: Int(battery.time_to_empty_min), timeToFull: Int(battery.time_to_full_min))
            } else {
                batteryResult = .failure(.init(operation: .battery, kind: .native(code.rawValue)))
            }
        }
        if hsc_supports(handle, HSC_CAP_CHATMIX_STATUS) {
            var chatmix = hsc_chatmix_t()
            let code = hsc_get_chatmix(handle, &chatmix)
            if code == HSC_RESULT_OK {
                chatmixResult = (0...128).contains(chatmix.level) ? .success(Int(chatmix.level))
                    : .failure(.init(operation: .chatmix, kind: .invalidResponse("Chatmix level \(chatmix.level)")))
            } else {
                chatmixResult = .failure(.init(operation: .chatmix, kind: .native(code.rawValue)))
            }
        }
        if hsc_supports(handle, HeadsetCapability.sidetoneStatus.rawValue) {
            var status = hsc_sidetone_status_t()
            let code = hsc_get_sidetone(handle, &status)
            if code == HSC_RESULT_OK {
                // The name can expire on the next query. Copy it before any more native I/O.
                let levelName = status.level_name.map { String(cString: $0) }
                sidetoneResult = HeadsetSidetone.decode(level: Int(status.current_level), deviceLevel: Int(status.device_level),
                                                       deviceMin: Int(status.device_min), deviceMax: Int(status.device_max),
                                                       levelName: levelName)
            } else {
                sidetoneResult = .failure(.init(operation: .sidetone, kind: .native(code.rawValue)))
            }
        }
        if hsc_supports(handle, HeadsetCapability.microphoneMuteStatus.rawValue) {
            var status = hsc_mic_mute_status_t()
            let code = hsc_get_mic_mute_status(handle, &status)
            microphoneMuted = code == HSC_RESULT_OK ? .success(status.muted)
                : .failure(.init(operation: .microphone, kind: .native(code.rawValue)))
        }
        if hsc_supports(handle, HeadsetCapability.microphoneAttachmentStatus.rawValue) {
            var status = hsc_mic_attachment_status_t()
            let code = hsc_get_mic_attachment_status(handle, &status)
            microphoneAttached = code == HSC_RESULT_OK ? .success(status.attached)
                : .failure(.init(operation: .boomMicrophone, kind: .native(code.rawValue)))
        }
        if hsc_supports(handle, HSC_CAP_EQUALIZER_PRESET) {
            equalizerPresets = HeadsetEqualizerPreset.read(count: Int(hsc_get_equalizer_presets_count(handle))) { index in
                guard let name = hsc_get_equalizer_preset_name(handle, Int32(index)) else { return nil }
                return String(cString: name) // Copy before the owning headset is freed.
            }
        }
        // Opening the device for a query can refine its product name. Copy the
        // native strings afterward, while this transaction still owns the handle.
        return HeadsetDevice(
            usbID: connection.usbID,
            name: stringFromC(hsc_get_name(handle)),
            vendor: stringFromC(hsc_get_vendor_name(handle)),
            product: stringFromC(hsc_get_product_name(handle)),
            capabilities: HeadsetCapability.menuCapabilities.compactMap {
                hsc_supports(handle, $0.rawValue) ? $0.legacyCapabilityString : nil
            },
            battery: batteryResult,
            chatmix: chatmixResult,
            sidetone: sidetoneResult,
            microphoneMuted: microphoneMuted,
            microphoneAttached: microphoneAttached,
            equalizerPresets: equalizerPresets
        )
    }

    func perform(_ command: HeadsetCommand, on connection: HeadsetConnection) -> Result<Void, HeadsetFailure> {
        assertWorker()
        let handle = handles[connection.index]
        switch command {
        case .anc(let mode):
            guard hsc_supports(handle, HSC_CAP_ANC) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            let range = AppDefaults.ancRange
            return HeadsetFailure.result(code: hsc_set_anc(handle, UInt8(max(range.lowerBound, min(range.upperBound, mode)))).rawValue, operation: .command)
        case .ancStartupMode(let mode):
            guard hsc_supports(handle, HSC_CAP_ANC_STARTUP_MODE) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            let range = AppDefaults.ancStartupModeRange
            return HeadsetFailure.result(code: hsc_set_anc_startup_mode(handle, UInt8(max(range.lowerBound, min(range.upperBound, mode)))).rawValue, operation: .command)
        case .ancButtonModes(let modes):
            guard hsc_supports(handle, HSC_CAP_ANC_BUTTON_MODES) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            guard modes.isValid else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_INVALID_PARAM.rawValue))) }
            var nativeModes = hsc_anc_button_modes_t(off: modes.contains(.off), anc: modes.contains(.anc), ambient: modes.contains(.ambient))
            return HeadsetFailure.result(code: hsc_set_anc_button_modes(handle, &nativeModes).rawValue, operation: .command)
        case .bluetoothCallVolume(let level):
            guard hsc_supports(handle, HSC_CAP_BT_CALL_VOLUME) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            let range = AppDefaults.bluetoothCallVolumeRange
            return HeadsetFailure.result(code: hsc_set_bluetooth_call_volume(handle, UInt8(max(range.lowerBound, min(range.upperBound, level)))).rawValue, operation: .command)
        case .bluetoothWhenPoweredOn(let enabled):
            guard hsc_supports(handle, HSC_CAP_BT_WHEN_POWERED_ON) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            return HeadsetFailure.result(code: hsc_set_bluetooth_when_powered_on(handle, enabled).rawValue, operation: .command)
        case .microphoneMuteLedBrightness(let level):
            guard hsc_supports(handle, HSC_CAP_MICROPHONE_MUTE_LED_BRIGHTNESS) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            let range = AppDefaults.microphoneMuteLedBrightnessRange
            return HeadsetFailure.result(code: hsc_set_mic_mute_led_brightness(handle, UInt8(max(range.lowerBound, min(range.upperBound, level)))).rawValue, operation: .command)
        case .volumeLimiter(let enabled):
            guard hsc_supports(handle, HSC_CAP_VOLUME_LIMITER) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            return HeadsetFailure.result(code: hsc_set_volume_limiter(handle, enabled).rawValue, operation: .command)
        case .noiseFilter(let level):
            guard hsc_supports(handle, HSC_CAP_NOISE_FILTER) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            let range = AppDefaults.noiseFilterRange
            return HeadsetFailure.result(code: hsc_set_noise_filter(handle, UInt8(max(range.lowerBound, min(range.upperBound, level)))).rawValue, operation: .command)
        case .microphoneVolume(let level):
            guard hsc_supports(handle, HSC_CAP_MICROPHONE_VOLUME) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            let range = AppDefaults.microphoneVolumeRange
            return HeadsetFailure.result(code: hsc_set_mic_volume(handle, UInt8(max(range.lowerBound, min(range.upperBound, level)))).rawValue, operation: .command)
        case .sidetone(let level):
            guard hsc_supports(handle, HSC_CAP_SIDETONE) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            return HeadsetFailure.result(code: hsc_set_sidetone(handle, UInt8(max(0, min(128, level))), nil).rawValue, operation: .command)
        case .lights(let enabled):
            guard hsc_supports(handle, HSC_CAP_LIGHTS) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            return HeadsetFailure.result(code: hsc_set_lights(handle, enabled).rawValue, operation: .command)
        case .inactiveTime(let minutes):
            guard hsc_supports(handle, HSC_CAP_INACTIVE_TIME) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            return HeadsetFailure.result(code: hsc_set_inactive_time(handle, UInt8(max(0, min(90, minutes))), nil).rawValue, operation: .command)
        case .voicePrompts(let enabled):
            guard hsc_supports(handle, HSC_CAP_VOICE_PROMPTS) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            return HeadsetFailure.result(code: hsc_set_voice_prompts(handle, enabled).rawValue, operation: .command)
        case .rotateToMute(let enabled):
            guard hsc_supports(handle, HSC_CAP_ROTATE_TO_MUTE) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            return HeadsetFailure.result(code: hsc_set_rotate_to_mute(handle, enabled).rawValue, operation: .command)
        case .equalizerPreset(let index):
            guard hsc_supports(handle, HSC_CAP_EQUALIZER_PRESET) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            let count = Int(hsc_get_equalizer_presets_count(handle))
            guard (1...255).contains(count), (0..<count).contains(index), let nativeIndex = UInt8(exactly: index) else {
                return .failure(.init(operation: .equalizer, kind: .unsupportedPreset(index)))
            }
            return HeadsetFailure.result(code: hsc_set_equalizer_preset(handle, nativeIndex).rawValue, operation: .command)
        }
    }

    func releaseDevices() {
        assertWorker()
        handles.removeAll()
        if let headsetsPointer { hsc_free_headsets(headsetsPointer, max(0, count)) }
        headsetsPointer = nil
        count = 0
    }

    func shutdown() {
        assertWorker()
        guard used else { return }
        releaseDevices()
        try? configure(testProfile: 0)
        // The C API exposes no shutdown function. HIDAPI is already a linked
        // dependency; exit here, before this thread and its run loop disappear.
        // No further library transaction is allowed after the worker stops.
        hid_exit()
        used = false
    }

    private func assertWorker() {
        precondition(HeadsetIOWorker.shared.isCurrentThread, "HID access requires its owning thread")
    }

    private func stringFromC(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(cString: pointer)
    }
}
