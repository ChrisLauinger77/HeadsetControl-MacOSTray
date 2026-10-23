import XCTest
@testable import HeadsetControl_MacOSTray

final class AppDefaultsTests: XCTestCase {
    func testMicrophoneMuteIconDefaultsOnAndPreservesOptOut() throws {
        let name = "MicrophoneIconDefaults.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        AppDefaults.register(in: store)
        XCTAssertTrue(store.bool(forKey: "showMicrophoneMuteIcon"))
        store.set(false, forKey: "showMicrophoneMuteIcon")
        AppDefaults.register(in: store)
        XCTAssertFalse(store.bool(forKey: "showMicrophoneMuteIcon"))
        store.set("invalid", forKey: "showMicrophoneMuteIcon")
        AppDefaults.validate(in: store)
        XCTAssertTrue(store.bool(forKey: "showMicrophoneMuteIcon"))
    }

    func testBluetoothCallVolumePresetsRegisterRepairAndPreserveCustomValues() throws {
        let name = "BluetoothCallVolumeTests.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        AppDefaults.register(in: store)
        XCTAssertEqual(AppDefaults.bluetoothCallVolumeKeys.map { store.integer(forKey: $0) }, [0, 25, 50, 75, 100])
        store.set(-100, forKey: "bluetoothCallVolumeOff")
        store.set(true, forKey: "bluetoothCallVolumeLow")
        store.set(43, forKey: "bluetoothCallVolumeMid")
        store.set(Int.max, forKey: "bluetoothCallVolumeMax")
        AppDefaults.validate(in: store)
        XCTAssertEqual(store.integer(forKey: "bluetoothCallVolumeOff"), -1)
        XCTAssertEqual(store.integer(forKey: "bluetoothCallVolumeLow"), 25)
        XCTAssertEqual(store.integer(forKey: "bluetoothCallVolumeMid"), 43)
        XCTAssertEqual(store.integer(forKey: "bluetoothCallVolumeMax"), 100)
    }

    func testMicrophoneVolumePresetsRegisterRepairAndPreserveHiddenEntries() throws {
        let name = "MicrophoneVolumeTests.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        AppDefaults.register(in: store)
        XCTAssertEqual(AppDefaults.microphoneVolumeKeys.map { store.integer(forKey: $0) }, [0, 32, 64, 96, 128])
        store.set(-1, forKey: "microphoneVolumeOff")
        store.set(Int.max, forKey: "microphoneVolumeHigh")
        store.set("invalid", forKey: "microphoneVolumeLow")
        AppDefaults.validate(in: store)
        XCTAssertEqual(store.integer(forKey: "microphoneVolumeOff"), -1)
        XCTAssertEqual(store.integer(forKey: "microphoneVolumeHigh"), 128)
        XCTAssertEqual(store.integer(forKey: "microphoneVolumeLow"), 32)
    }

    func testLanguageSelectionOverridesAndRestoresSystemPreference() throws {
        let name = "HeadsetLanguageTests.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }

        XCTAssertEqual(AppDefaults.selectedLanguage(in: store, domain: name), "")
        AppDefaults.setLanguage("de", in: store)
        XCTAssertEqual(AppDefaults.selectedLanguage(in: store, domain: name), "de")
        XCTAssertEqual(store.persistentDomain(forName: name)?["AppleLanguages"] as? [String], ["de"])

        AppDefaults.setLanguage("", in: store)
        XCTAssertEqual(AppDefaults.selectedLanguage(in: store, domain: name), "")
        XCTAssertNil(store.persistentDomain(forName: name)?["AppleLanguages"])
    }

    func testSnapshotAgeUsesTheValidatedIntervalAndGrace() {
        for (interval, threshold) in [(60, 120), (300, 360), (900, 960), (3600, 3660)] {
            XCTAssertEqual(AppDefaults.snapshotMaximumAge(for: interval), Double(threshold))
        }
        XCTAssertEqual(AppDefaults.snapshotMaximumAge(for: -1), 120)
        XCTAssertEqual(AppDefaults.snapshotMaximumAge(for: Int.max), 3660)
        for invalid: Any? in [nil, Double.nan, Double.infinity, "invalid", true] {
            XCTAssertEqual(AppDefaults.snapshotMaximumAge(for: invalid), 660)
        }
    }

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
        XCTAssertEqual(AppDefaults.testProfiles, [0, 1, 2, 3, 4, 5, 6, 7, 10])
        for profile in AppDefaults.testProfiles { XCTAssertEqual(AppDefaults.validatedTestProfile(profile), profile) }
        XCTAssertEqual(AppDefaults.validatedTestProfile(10.0), 10)
        for value: Any in [-1, 8, 9, 11, Int.max, 2.5, 10.5, Double.nan, "7", "10", true] {
            XCTAssertEqual(AppDefaults.validatedTestProfile(value), 0)
        }
    }

    func testSharedSettingsPolicyPreservesHiddenSidetoneAndPresetPositions() {
        XCTAssertEqual(AppDefaults.validatedSidetone(-1, fallback: 32), -1)
        XCTAssertEqual(AppDefaults.parseInactiveTimeOptions("90,1,1,999,abc,15"), [1, 15, 90])
        XCTAssertEqual(AppDefaults.presetName(index: 2, fallbackNames: "Game,,Voice"), "Voice")
    }
}
