import Foundation
import IOKit
import HeadsetControlCLib

// USB registry entries group multiple HID interfaces on one receiver into
// one attachment. HID enumeration excludes conflicting non-USB transports.
// Registry IDs last only for this attachment, never as persisted identity.
nonisolated struct HeadsetUSBInventory: HeadsetUSBInventoryProviding {
    func attachments() -> [HeadsetUSBID: [UInt64]]? {
        precondition(HeadsetIOWorker.shared.isCurrentThread)
        // headsetcontrol searches all HID transports by VID/PID. A matching
        // Bluetooth or unknown-transport entry would make even a unique USB
        // receiver unsafe to select. Exclude those models rather than guess.
        guard let enumeration = hid_enumerate(0, 0) else { return nil }
        defer { hid_free_enumeration(enumeration) }
        var excludedModels: Set<HeadsetUSBID> = []
        var current: UnsafeMutablePointer<hid_device_info>? = enumeration
        while let entry = current {
            let info = entry.pointee
            if info.bus_type != HID_API_BUS_USB {
                excludedModels.insert(HeadsetUSBID(vendor: info.vendor_id, product: info.product_id))
            }
            current = info.next
        }

        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOUSBHostDevice"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [HeadsetUSBID: [UInt64]] = [:]
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard let vendor = IORegistryEntryCreateCFProperty(device, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
                  let product = IORegistryEntryCreateCFProperty(device, "idProduct" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return nil }
            var attachmentID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(device, &attachmentID) == KERN_SUCCESS else { return nil }
            let id = HeadsetUSBID(vendor: vendor.uint16Value, product: product.uint16Value)
            if !excludedModels.contains(id) { result[id, default: []].append(attachmentID) }
        }
        guard IOIteratorIsValid(iterator) != 0 else { return nil }
        return result
    }
}
