import Foundation
import HeadsetControlCLib

// This is the only owner of native handles. Configure, discovery, I/O, freeing
// handles and HID teardown all run on HeadsetIOWorker.shared's fixed thread.
nonisolated final class NativeHeadsetLibrary: HeadsetLibraryAccess {
    private var headsetsPointer: UnsafeMutablePointer<hsc_headset_t?>?
    private var count: Int32 = 0
    private var handles: [hsc_headset_t] = []
    private var used = false

    func configure(testProfile: Int) {
        assertWorker()
        used = true
        let profile = Int32(clamping: max(0, testProfile))
        hsc_set_test_profile(profile)
        hsc_enable_test_device(profile > 0)
    }

    func discover() -> [HeadsetConnection] {
        assertWorker()
        precondition(headsetsPointer == nil && handles.isEmpty)
        count = hsc_discover(&headsetsPointer)
        guard count > 0, let headsetsPointer else { return [] }
        handles = UnsafeBufferPointer(start: headsetsPointer, count: Int(count)).compactMap { $0 }
        return handles.enumerated().map { index, handle in
            HeadsetConnection(index: index, usbID: HeadsetUSBID(vendor: hsc_get_vendor_id(handle), product: hsc_get_product_id(handle)))
        }
    }

    func readDevice(_ connection: HeadsetConnection) -> HeadsetDevice {
        assertWorker()
        let handle = handles[connection.index]
        var device = HeadsetDevice(
            usbID: connection.usbID,
            name: stringFromC(hsc_get_name(handle)),
            vendor: stringFromC(hsc_get_vendor_name(handle)),
            product: stringFromC(hsc_get_product_name(handle)),
            capabilities: HeadsetCapability.menuCapabilities.compactMap {
                hsc_supports(handle, $0.rawValue) ? $0.legacyCapabilityString : nil
            }
        )
        if hsc_supports(handle, HSC_CAP_BATTERY_STATUS) {
            var battery = hsc_battery_t()
            if hsc_get_battery(handle, &battery) == HSC_RESULT_OK {
                device.battery = .init(
                    level: Int(battery.level_percent), status: legacyBatteryStatusString(battery.status),
                    timeToEmpty: battery.time_to_empty_min >= 0 ? Int(battery.time_to_empty_min) : nil
                )
            }
        }
        if hsc_supports(handle, HSC_CAP_CHATMIX_STATUS) {
            var chatmix = hsc_chatmix_t()
            if hsc_get_chatmix(handle, &chatmix) == HSC_RESULT_OK { device.chatmix = Int(chatmix.level) }
        }
        return device
    }

    func perform(_ command: HeadsetCommand, on connection: HeadsetConnection) -> Bool {
        assertWorker()
        let handle = handles[connection.index]
        switch command {
        case .sidetone(let level):
            guard hsc_supports(handle, HSC_CAP_SIDETONE) else { return false }
            return hsc_set_sidetone(handle, UInt8(max(0, min(128, level))), nil) == HSC_RESULT_OK
        case .lights(let enabled):
            guard hsc_supports(handle, HSC_CAP_LIGHTS) else { return false }
            return hsc_set_lights(handle, enabled) == HSC_RESULT_OK
        case .inactiveTime(let minutes):
            guard hsc_supports(handle, HSC_CAP_INACTIVE_TIME) else { return false }
            return hsc_set_inactive_time(handle, UInt8(max(0, min(90, minutes))), nil) == HSC_RESULT_OK
        case .voicePrompts(let enabled):
            guard hsc_supports(handle, HSC_CAP_VOICE_PROMPTS) else { return false }
            return hsc_set_voice_prompts(handle, enabled) == HSC_RESULT_OK
        case .rotateToMute(let enabled):
            guard hsc_supports(handle, HSC_CAP_ROTATE_TO_MUTE) else { return false }
            return hsc_set_rotate_to_mute(handle, enabled) == HSC_RESULT_OK
        case .equalizerPreset(let index):
            guard hsc_supports(handle, HSC_CAP_EQUALIZER_PRESET) else { return false }
            return hsc_set_equalizer_preset(handle, UInt8(max(0, min(255, index)))) == HSC_RESULT_OK
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
        configure(testProfile: 0)
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
