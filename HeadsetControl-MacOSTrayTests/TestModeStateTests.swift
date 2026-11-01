import XCTest
@testable import HeadsetControl_MacOSTray

@MainActor final class TestModeStateTests: XCTestCase {
    func testSettingsRecreationKeepsSessionProfileAndNewSessionStartsDisabled() {
        let session = TestModeState()
        XCTAssertEqual(session.profile, 0)
        let settings = SettingsView(testMode: session)
        settings.testMode.profile = 7

        let reopenedSettings = SettingsView(testMode: session)
        XCTAssertEqual(reopenedSettings.testMode.profile, 7)
        XCTAssertEqual(TestModeState().profile, 0)
        XCTAssertNil(AppDefaults.standard.object(forKey: "testMode"))
    }

    func testProfileSelectionValidatesBeforeItCanReachTheProvider() {
        let session = TestModeState()
        for profile in AppDefaults.testProfiles {
            session.profile = profile
            XCTAssertEqual(session.profile, profile)
        }
        for profile in [-1, 9, 11, Int.max] {
            session.profile = 7
            session.profile = profile
            XCTAssertEqual(session.profile, 0)
        }
    }
}
