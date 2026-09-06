import XCTest
@testable import HeadsetControl_MacOSTray

private final class RecordingHeadsetLibrary: HeadsetLibraryAccess {
    var connections: [HeadsetConnection] = []
    var reads: [HeadsetConnection] = []
    var writes: [(HeadsetCommand, HeadsetConnection)] = []
    var events: [String] = []
    var onDiscover: (() -> Void)?
    var succeeds = true

    func configure(testProfile: Int) { events.append("profile:\(testProfile)") }
    func discover() -> [HeadsetConnection] {
        events.append("discover")
        onDiscover?()
        return connections
    }
    func readDevice(_ connection: HeadsetConnection) -> HeadsetDevice {
        reads.append(connection)
        return HeadsetDevice(usbID: connection.usbID, name: "Headset", vendor: "Vendor", product: "Product", capabilities: ["CAP_LIGHTS"])
    }
    func perform(_ command: HeadsetCommand, on connection: HeadsetConnection) -> Bool {
        writes.append((command, connection))
        return succeeds
    }
    func releaseDevices() { events.append("release") }
    func shutdown() { events.append("shutdown") }
}

private final class FakeUSBInventory: HeadsetUSBInventoryProviding {
    var devices: [HeadsetUSBID: [UInt64]]? = [:]
    func attachments() -> [HeadsetUSBID: [UInt64]]? { devices }
}

final class HeadsetControlServiceTests: XCTestCase {
    private let a = HeadsetUSBID(vendor: 1, product: 2)
    private let b = HeadsetUSBID(vendor: 3, product: 4)

    func testEveryCommandSelectsOnlyItsInitiatingDevice() {
        let library = RecordingHeadsetLibrary()
        let inventory = FakeUSBInventory()
        library.connections = [HeadsetConnection(index: 0, usbID: a), HeadsetConnection(index: 1, usbID: b)]
        inventory.devices = [a: [11], b: [22]]
        let service = HeadsetControlService(library: library, inventory: inventory)
        let commands: [HeadsetCommand] = [.sidetone(10), .lights(false), .inactiveTime(5), .voicePrompts(true), .rotateToMute(false), .equalizerPreset(1)]
        for command in commands {
            XCTAssertTrue(service.perform(command, on: .physical(b, attachmentID: 22), testProfile: 0))
        }
        XCTAssertEqual(library.writes.map { $0.0 }, commands)
        XCTAssertEqual(library.writes.map { $0.1.usbID }, Array(repeating: b, count: commands.count))
    }

    func testTestModeNeverReadsOrCommandsPhysicalDevices() {
        let library = RecordingHeadsetLibrary()
        let inventory = FakeUSBInventory()
        let fake = HeadsetConnection(index: 1, usbID: .testDevice)
        library.connections = [HeadsetConnection(index: 0, usbID: a), fake]
        let service = HeadsetControlService(library: library, inventory: inventory)
        XCTAssertEqual(service.fetchDevices(testProfile: 7).map(\.target), [.test(profile: 7)])
        XCTAssertEqual(library.reads, [fake])
        XCTAssertTrue(service.perform(.lights(false), on: .test(profile: 7), testProfile: 7))
        XCTAssertEqual(library.writes.map { $0.1 }, [fake])

        library.connections = [HeadsetConnection(index: 0, usbID: a)]
        XCTAssertFalse(service.perform(.lights(false), on: .test(profile: 7), testProfile: 7))
        XCTAssertFalse(service.perform(.lights(false), on: .physical(a, attachmentID: 11), testProfile: 7))
        XCTAssertFalse(service.perform(.lights(false), on: .test(profile: 7), testProfile: 0))
        XCTAssertFalse(service.perform(.lights(false), on: .test(profile: 7), testProfile: 8))
        XCTAssertEqual(library.writes.count, 1)
    }

    func testMissingAmbiguousOrReplacedAttachmentsFailClosed() {
        let library = RecordingHeadsetLibrary()
        let inventory = FakeUSBInventory()
        library.connections = [HeadsetConnection(index: 0, usbID: a)]
        let service = HeadsetControlService(library: library, inventory: inventory)
        let cases: [[HeadsetUSBID: [UInt64]]?] = [nil, [:], [a: [12]], [a: [11, 12]]]
        for attachments in cases {
            inventory.devices = attachments
            XCTAssertFalse(service.perform(.lights(false), on: .physical(a, attachmentID: 11), testProfile: 0))
        }
        inventory.devices = [a: [11, 12]]
        XCTAssertNil(service.fetchDevices(testProfile: 0).first?.target)
        inventory.devices = [a: [11]]
        XCTAssertEqual(service.fetchDevices(testProfile: 0).first?.target, .physical(a, attachmentID: 11))
        library.connections = []
        XCTAssertFalse(service.perform(.lights(false), on: .physical(a, attachmentID: 11), testProfile: 0))
        XCTAssertTrue(library.writes.isEmpty)
    }

    func testAttachmentChangeDuringDiscoveryPreventsCommand() {
        let library = RecordingHeadsetLibrary()
        let inventory = FakeUSBInventory()
        library.connections = [HeadsetConnection(index: 0, usbID: a)]
        inventory.devices = [a: [11]]
        let service = HeadsetControlService(library: library, inventory: inventory)
        library.onDiscover = { inventory.devices = [self.a: [12]] }
        XCTAssertFalse(service.perform(.lights(false), on: .physical(a, attachmentID: 11), testProfile: 0))
        XCTAssertTrue(library.writes.isEmpty)
        XCTAssertEqual(Array(library.events.suffix(2)), ["release", "profile:0"])
    }

    func testReentrantTransactionIsRejectedAndFailureStillReleasesResources() {
        let library = RecordingHeadsetLibrary()
        let inventory = FakeUSBInventory()
        library.connections = [HeadsetConnection(index: 0, usbID: .testDevice)]
        let service = HeadsetControlService(library: library, inventory: inventory)
        library.onDiscover = {
            XCTAssertTrue(service.fetchDevices(testProfile: 8).isEmpty)
            XCTAssertFalse(service.perform(.lights(false), on: .test(profile: 7), testProfile: 7))
        }
        library.succeeds = false
        XCTAssertFalse(service.perform(.lights(false), on: .test(profile: 7), testProfile: 7))
        XCTAssertEqual(library.events, ["profile:7", "discover", "release", "profile:0"])
        service.shutdown()
        service.shutdown()
        XCTAssertEqual(library.events.last, "shutdown")
        XCTAssertTrue(service.fetchDevices(testProfile: 7).isEmpty)
        XCTAssertEqual(library.events.filter { $0 == "shutdown" }.count, 1)
    }
}
