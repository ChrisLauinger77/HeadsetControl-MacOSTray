import XCTest
@testable import HeadsetControl_MacOSTray

class AppDelegateTests: XCTestCase {
    func testDefaultUpdateInterval() {
        let appDelegate = AppDelegate()
        // Default value should be 600 if not set
        UserDefaults.standard.removeObject(forKey: "updateInterval")
        XCTAssertEqual(appDelegate.updateInterval, 600)
    }
}
