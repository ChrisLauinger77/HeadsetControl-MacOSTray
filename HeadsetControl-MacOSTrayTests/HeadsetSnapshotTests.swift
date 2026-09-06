import XCTest
@testable import HeadsetControl_MacOSTray

final class HeadsetSnapshotTests: XCTestCase {
    func testObservationRemainsFreshThroughPollingIntervalAndGrace() {
        for (interval, threshold): (TimeInterval, TimeInterval) in [(60, 120), (300, 360), (900, 960), (3600, 3660)] {
            var snapshot = HeadsetSnapshot()
            let date = Date(timeIntervalSince1970: 100)
            XCTAssertEqual(snapshot.state(at: date, maximumAge: threshold), .unobserved)
            snapshot.observe(.success([headset()]), at: date)
            for age in [60, interval, interval + 30, threshold - 0.001] {
                XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(age), maximumAge: threshold), .fresh)
            }
            XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(threshold), maximumAge: threshold), .stale)
            XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(threshold + 1), maximumAge: threshold), .stale)
            XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(-1), maximumAge: threshold), .stale)
            XCTAssertEqual(snapshot.observedAt, date)
        }
    }

    func testFailureRetainsCachedObservationAndEmptySuccessReplacesIt() {
        var snapshot = HeadsetSnapshot()
        let date = Date(timeIntervalSince1970: 100)
        snapshot.observe(.success([headset()]), at: date)
        let error = HeadsetFailure(operation: .discovery, kind: .native(-5))
        snapshot.observe(.failure(error), at: date.addingTimeInterval(5))
        XCTAssertEqual(snapshot.state(at: date, maximumAge: 3660), .failed)
        XCTAssertEqual(snapshot.failure, error)
        XCTAssertEqual(snapshot.devices?.count, 1)
        XCTAssertEqual(snapshot.observedAt, date)
        snapshot.observe(.success([]), at: date.addingTimeInterval(10))
        XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(10), maximumAge: 3660), .empty)
        XCTAssertEqual(snapshot.devices?.count, 0)
        XCTAssertNil(snapshot.failure)
        snapshot.invalidate()
        XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(10), maximumAge: 3660), .stale)
    }

    func testAgeExpirationIsReversibleButExplicitInvalidationIsNot() {
        var snapshot = HeadsetSnapshot()
        let date = Date(timeIntervalSince1970: 100)
        snapshot.observe(.success([headset()]), at: date)
        let now = date.addingTimeInterval(200)
        XCTAssertEqual(snapshot.state(at: now, maximumAge: 120), .stale)
        XCTAssertEqual(snapshot.state(at: now, maximumAge: 960), .fresh)
        XCTAssertEqual(snapshot.state(at: now, maximumAge: 120), .stale)
        snapshot.invalidate()
        XCTAssertEqual(snapshot.state(at: now, maximumAge: 960), .stale)
        XCTAssertEqual(snapshot.state(at: now, maximumAge: 3660), .stale)
    }

    func testEmptyObservationUsesTheSameFreshnessWindow() {
        var snapshot = HeadsetSnapshot()
        let date = Date(timeIntervalSince1970: 100)
        snapshot.observe(.success([]), at: date)
        XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(959), maximumAge: 960), .empty)
        XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(960), maximumAge: 960), .stale)
        XCTAssertEqual(snapshot.state(at: date.addingTimeInterval(960), maximumAge: 3660), .empty)
    }

    private func headset() -> HeadsetDevice {
        HeadsetDevice(usbID: .testDevice, name: "Fake", vendor: "Vendor", product: "Product", capabilities: [])
    }
}
