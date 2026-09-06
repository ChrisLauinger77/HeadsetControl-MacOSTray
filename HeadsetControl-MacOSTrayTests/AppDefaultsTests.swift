import XCTest
@testable import HeadsetControl_MacOSTray

final class AppDefaultsTests: XCTestCase {
    func testRegistrationSuppliesIntendedSidetoneValuesBeforeAnySettingsUI() throws {
        let name = "HeadsetDefaultsTests.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        AppDefaults.register(in: store)
        XCTAssertEqual(AppDefaults.sidetoneKeys.map { store.integer(forKey: $0) }, [0, 32, 64, 96, 128])
        XCTAssertEqual(store.integer(forKey: "updateInterval"), 600)
        XCTAssertEqual(store.integer(forKey: "lowBatteryThreshold"), 25)
        XCTAssertTrue(store.bool(forKey: "notifyOnLowBattery"))
        XCTAssertNil(store.persistentDomain(forName: name)?["sidetoneLow"])
        store.set(12, forKey: "sidetoneLow")
        AppDefaults.register(in: store)
        XCTAssertEqual(store.integer(forKey: "sidetoneLow"), 12)
    }

    func testPersistedIntervalsAndProfilesAreRepairedWithoutUnsafeConversions() throws {
        let name = "HeadsetDefaultsTests.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        store.set(-5, forKey: "updateInterval")
        store.set(Int.max, forKey: "testMode")
        AppDefaults.register(in: store)
        XCTAssertEqual(store.integer(forKey: "updateInterval"), 60)
        XCTAssertEqual(store.integer(forKey: "testMode"), 0)
        XCTAssertEqual(AppDefaults.validatedUpdateInterval(Int.max), 3600)
        XCTAssertEqual(AppDefaults.validatedUpdateInterval(Double.nan), 600)
        XCTAssertEqual(AppDefaults.validatedUpdateInterval(Double.infinity), 600)
        XCTAssertEqual(AppDefaults.validatedUpdateInterval("invalid"), 600)
        XCTAssertEqual(AppDefaults.validatedUpdateInterval(true), 600)
        XCTAssertEqual(AppDefaults.validatedUpdateInterval(60.4), 60)
        for profile in 0...7 { XCTAssertEqual(AppDefaults.validatedTestProfile(profile), profile) }
        for value: Any in [-1, 8, Int.max, 2.5, Double.nan, "7", true] {
            XCTAssertEqual(AppDefaults.validatedTestProfile(value), 0)
        }
    }

    func testSharedSettingsPolicyPreservesHiddenSidetoneAndPresetPositions() {
        XCTAssertEqual(AppDefaults.validatedSidetone(-1, fallback: 32), -1)
        XCTAssertEqual(AppDefaults.parseInactiveTimeOptions("90,1,1,999,abc,15"), [1, 15, 90])
        XCTAssertEqual(AppDefaults.presetName(index: 2, fallbackNames: "Game,,Voice"), "Voice")
    }
}
