import XCTest
@testable import HeadsetControl_MacOSTray

class AppDelegateTests: XCTestCase {
    func testDefaultUpdateInterval() {
        let appDelegate = AppDelegate()
        // Default value should be 600 if not set
        UserDefaults.standard.removeObject(forKey: "updateInterval")
        XCTAssertEqual(appDelegate.updateInterval, 600)
    }

    func testDefaultLowBatteryThreshold() {
        UserDefaults.standard.removeObject(forKey: "lowBatteryThreshold")
        let appDelegate = AppDelegate()
        XCTAssertEqual(appDelegate.lowBatteryThreshold, 25)
    }

    func testLowBatteryThresholdClampsToValidRange() {
        let appDelegate = AppDelegate()
        defer { UserDefaults.standard.removeObject(forKey: "lowBatteryThreshold") }

        appDelegate.lowBatteryThreshold = 99
        XCTAssertEqual(appDelegate.lowBatteryThreshold, 30)

        appDelegate.lowBatteryThreshold = -5
        XCTAssertEqual(appDelegate.lowBatteryThreshold, 1)
    }

    func testLowBatteryTestProfileReturnsAvailableBatteryStatus() throws {
        let service = HeadsetControlService()
        service.setTestProfile(7)
        defer { service.setTestProfile(0) }

        let battery = try XCTUnwrap(service.fetchDevices().first?["battery"] as? [String: Any])
        XCTAssertEqual(battery["level"] as? Int, 10)
        XCTAssertEqual(battery["status"] as? String, "BATTERY_AVAILABLE")
    }
}
