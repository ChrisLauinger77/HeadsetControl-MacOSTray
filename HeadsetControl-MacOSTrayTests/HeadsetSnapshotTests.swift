import XCTest
@testable import HeadsetControl_MacOSTray

final class HeadsetSnapshotTests: XCTestCase {
    func testObservationAgesAndClockRollbackCannotMakeItFresh() {
        var snapshot = HeadsetSnapshot()
        let date = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(snapshot.state(at: date), .unobserved)
        snapshot.observe(.success([headset()]), at: date)
        XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(59)), .fresh)
        XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(60)), .stale)
        XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(-1)), .stale)
        XCTAssertEqual(snapshot.observedAt, date)
    }

    func testFailureRetainsCachedObservationAndEmptySuccessReplacesIt() {
        var snapshot = HeadsetSnapshot()
        let date = Date(timeIntervalSince1970: 100)
        snapshot.observe(.success([headset()]), at: date)
        let error = HeadsetFailure(operation: .discovery, kind: .native(-5))
        snapshot.observe(.failure(error), at: date.addingTimeInterval(5))
        XCTAssertEqual(snapshot.state(at: date), .failed)
        XCTAssertEqual(snapshot.failure, error)
        XCTAssertEqual(snapshot.devices?.count, 1)
        XCTAssertEqual(snapshot.observedAt, date)
        snapshot.observe(.success([]), at: date.addingTimeInterval(10))
        XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(10)), .empty)
        XCTAssertEqual(snapshot.devices?.count, 0)
        XCTAssertNil(snapshot.failure)
        snapshot.invalidate()
        XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(10)), .stale)
    }

    private func headset() -> HeadsetDevice {
        HeadsetDevice(usbID: .testDevice, name: "Fake", vendor: "Vendor", product: "Product", capabilities: [])
    }
}
