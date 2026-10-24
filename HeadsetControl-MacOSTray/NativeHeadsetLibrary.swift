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
        guard AppDefaults.isSupportedTestProfile(testProfile) else {
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
        var headsetVolumeResult: Result<HeadsetVolume, HeadsetFailure>?
        var microphoneMuted: Result<Bool, HeadsetFailure>?
        var microphoneAttached: Result<Bool, HeadsetFailure>?
        var equalizerPresets: Result<[HeadsetEqualizerPreset], HeadsetFailure>?
        let equalizerInfo = hsc_supports(handle, HSC_CAP_EQUALIZER) ? readGraphicInfo(handle) : nil
        let parametricInfo = hsc_supports(handle, HSC_CAP_PARAMETRIC_EQUALIZER) ? readParametricInfo(handle) : nil
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
        // Setting support alone does not imply a getter. In particular, the A50
        // can be controlled before upstream implements its volume readback.
        if hsc_supports(handle, HSC_CAP_HEADSET_VOLUME),
           hsc_get_readable_capabilities(handle) & (1 << HSC_CAP_HEADSET_VOLUME.rawValue) != 0 {
            var volume = hsc_headset_volume_t()
            let code = hsc_get_headset_volume(handle, &volume)
            if code == HSC_RESULT_OK {
                headsetVolumeResult = HeadsetVolume.decode(level: Int(volume.volume), minLevel: Int(volume.min_volume),
                                                           maxLevel: Int(volume.max_volume), deviceLevel: Int(volume.device_volume),
                                                           deviceMin: Int(volume.device_min), deviceMax: Int(volume.device_max))
            } else {
                headsetVolumeResult = .failure(.init(operation: .headsetVolume, kind: .native(code.rawValue)))
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
            if case .success(let info) = equalizerInfo, case .success(let presets) = equalizerPresets {
                equalizerPresets = .success(presets.map { preset in
                    var preset = preset
                    let count = Int(hsc_get_equalizer_preset_band_count(handle, Int32(preset.index)))
                    guard count == info.count else { return preset }
                    var bands = [Float](repeating: 0, count: count)
                    let code = bands.withUnsafeMutableBufferPointer {
                        hsc_get_equalizer_preset_bands(handle, Int32(preset.index), $0.baseAddress, Int32(count))
                    }
                    let values = bands.map(Double.init)
                    if code != HSC_RESULT_OK {
                        preset.bands = .failure(.init(operation: .equalizer, kind: .native(code.rawValue)))
                    } else if info.accepts(values) {
                        preset.bands = .success(values)
                    } else {
                        preset.bands = .failure(.init(operation: .equalizer, kind: .invalidResponse("Preset bands")))
                    }
                    return preset
                })
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
            headsetVolume: headsetVolumeResult,
            microphoneMuted: microphoneMuted,
            microphoneAttached: microphoneAttached,
            equalizerPresets: equalizerPresets,
            equalizerInfo: equalizerInfo,
            parametricEqualizerInfo: parametricInfo
        )
    }

    func perform(_ command: HeadsetCommand, on connection: HeadsetConnection) -> Result<Void, HeadsetFailure> {
        assertWorker()
        let handle = handles[connection.index]
        switch command {
        case .customEqualizer(let curve):
            guard curve.isValid else {
                return .failure(.init(operation: .equalizer, kind: .native(HSC_RESULT_INVALID_PARAM.rawValue)))
            }
            // Re-read on this transaction's selected handle. A saved signature
            // or a current-looking Settings draft is never enough to authorize I/O.
            switch curve {
            case .graphic(let info, let values):
                guard hsc_supports(handle, HSC_CAP_EQUALIZER) else {
                    return .failure(.init(operation: .equalizer, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue)))
                }
                switch readGraphicInfo(handle) {
                case .failure(let error): return .failure(error)
                case .success(let current):
                    guard current == info else { return .failure(.init(operation: .equalizer, kind: .equalizerLayoutChanged)) }
                }
                let bands = values.map(Float.init)
                let code = bands.withUnsafeBufferPointer { hsc_set_equalizer(handle, $0.baseAddress, Int32($0.count)) }
                return HeadsetFailure.result(code: code.rawValue, operation: .equalizer)
            case .parametric(let info, let values):
                guard hsc_supports(handle, HSC_CAP_PARAMETRIC_EQUALIZER) else {
                    return .failure(.init(operation: .equalizer, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue)))
                }
                switch readParametricInfo(handle) {
                case .failure(let error): return .failure(error)
                case .success(let current):
                    guard current == info else { return .failure(.init(operation: .equalizer, kind: .equalizerLayoutChanged)) }
                }
                let bands = values.map {
                    hsc_parametric_band_t(frequency: Float($0.frequency), gain: Float($0.gain), q_factor: Float($0.q),
                                          type: hsc_eq_filter_type_t(rawValue: UInt32($0.filter.rawValue)))
                }
                let code = bands.withUnsafeBufferPointer { hsc_set_parametric_equalizer(handle, $0.baseAddress, Int32($0.count)) }
                return HeadsetFailure.result(code: code.rawValue, operation: .equalizer)
            }
        case .headsetVolume(let level):
            guard hsc_supports(handle, HSC_CAP_HEADSET_VOLUME) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            guard AppDefaults.headsetVolumeRange.contains(level), let nativeLevel = UInt8(exactly: level) else {
                return .failure(.init(operation: .command, kind: .native(HSC_RESULT_INVALID_PARAM.rawValue)))
            }
            return HeadsetFailure.result(code: hsc_set_headset_volume(handle, nativeLevel, nil).rawValue, operation: .command)
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
        case .lightColor(let color):
            guard hsc_supports(handle, HSC_CAP_LIGHT_COLOR) else { return .failure(.init(operation: .command, kind: .native(HSC_RESULT_NOT_SUPPORTED.rawValue))) }
            return HeadsetFailure.result(code: hsc_set_light_color(handle, color.red, color.green, color.blue).rawValue, operation: .command)
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

    private func readGraphicInfo(_ handle: hsc_headset_t) -> Result<GraphicEqualizerInfo, HeadsetFailure> {
        var native = hsc_equalizer_info_t()
        let code = hsc_get_equalizer_info(handle, &native)
        guard code == HSC_RESULT_OK else { return .failure(.init(operation: .equalizer, kind: .native(code.rawValue))) }
        let info = GraphicEqualizerInfo(count: Int(native.bands_count), baseline: Double(native.bands_baseline),
                                       step: Double(native.bands_step), minimum: Double(native.bands_min), maximum: Double(native.bands_max))
        return info.isValid ? .success(info) : .failure(.init(operation: .equalizer, kind: .invalidResponse("Graphic EQ layout")))
    }

    private func readParametricInfo(_ handle: hsc_headset_t) -> Result<ParametricEqualizerInfo, HeadsetFailure> {
        var native = hsc_parametric_equalizer_info_t()
        let code = hsc_get_parametric_equalizer_info(handle, &native)
        guard code == HSC_RESULT_OK else { return .failure(.init(operation: .equalizer, kind: .native(code.rawValue))) }
        let info = ParametricEqualizerInfo(count: Int(native.bands_count), baseline: Double(native.gain_base),
                                          step: Double(native.gain_step), minimum: Double(native.gain_min), maximum: Double(native.gain_max),
                                          qMinimum: Double(native.q_factor_min), qMaximum: Double(native.q_factor_max),
                                          frequencyMinimum: Double(native.freq_min), frequencyMaximum: Double(native.freq_max),
                                          filterMask: Int(native.filter_types))
        return info.isValid ? .success(info) : .failure(.init(operation: .equalizer, kind: .invalidResponse("Parametric EQ layout")))
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
