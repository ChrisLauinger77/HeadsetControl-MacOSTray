import Foundation

// Handles are transaction-local indexes. Native pointers never leave the adapter.
nonisolated struct HeadsetConnection: Equatable {
    let index: Int
    let usbID: HeadsetUSBID
}

nonisolated protocol HeadsetLibraryAccess: AnyObject {
    func configure(testProfile: Int) throws(HeadsetFailure)
    func discover() -> Result<[HeadsetConnection], HeadsetFailure>
    func readDevice(_ connection: HeadsetConnection) -> HeadsetDevice
    func perform(_ command: HeadsetCommand, on connection: HeadsetConnection) -> Result<Void, HeadsetFailure>
    func releaseDevices()
    func shutdown()
}

nonisolated protocol HeadsetUSBInventoryProviding {
    // nil means enumeration failed; an empty array means no matching attachment.
    func attachments() -> [HeadsetUSBID: [UInt64]]?
}
