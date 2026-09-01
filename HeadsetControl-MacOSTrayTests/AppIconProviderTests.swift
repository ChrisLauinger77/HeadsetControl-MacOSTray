import XCTest
@testable import HeadsetControl_MacOSTray

final class AppIconProviderTests: XCTestCase {
    func testLightAndDarkIconsAreAvailable() {
        XCTAssertNotNil(AppIconProvider.image(isDark: false))
        XCTAssertNotNil(AppIconProvider.image(isDark: true))
    }
}
