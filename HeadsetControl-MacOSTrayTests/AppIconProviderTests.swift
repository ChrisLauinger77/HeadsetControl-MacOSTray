import XCTest
@testable import HeadsetControl_MacOSTray

final class AppIconProviderTests: XCTestCase {
    func testMuteIconFollowsTheFirstSuccessfulReporterOnly() {
        let failure = HeadsetFailure(operation: .microphone, kind: .native(-4))
        let cases: [([Result<Bool, HeadsetFailure>?], AppIconProvider.StatusIcon)] = [
            ([], .headset), ([nil], .headset), ([.failure(failure)], .headset),
            ([nil, .success(true)], .microphoneMuted),
            ([.failure(failure), .success(true)], .microphoneMuted),
            ([.success(false), .success(true)], .headset),
            ([.success(true), .success(false)], .microphoneMuted)
        ]
        for (statuses, expected) in cases {
            XCTAssertEqual(AppIconProvider.statusIcon(muteStatuses: statuses, showMuted: true), expected)
            XCTAssertEqual(AppIconProvider.statusIcon(muteStatuses: statuses, showMuted: false), .headset)
        }
    }

    func testNormalAndMutedStatusIconsAreAvailableAndAdaptToAppearance() throws {
        for icon in [AppIconProvider.StatusIcon.headset, .microphoneMuted] {
            let image = try XCTUnwrap(AppIconProvider.image(for: icon))
            XCTAssertTrue(image.isTemplate)
        }
        XCTAssertNotEqual(AppIconProvider.StatusIcon.headset.rawValue, AppIconProvider.StatusIcon.microphoneMuted.rawValue)
    }

    func testLightAndDarkIconsAreAvailable() {
        XCTAssertNotNil(AppIconProvider.image(isDark: false))
        XCTAssertNotNil(AppIconProvider.image(isDark: true))
    }
}
