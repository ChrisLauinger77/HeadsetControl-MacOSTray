import AppKit
import XCTest
@testable import HeadsetControl_MacOSTray

class AppDelegateTests: XCTestCase {
    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "updateInterval")
        UserDefaults.standard.removeObject(forKey: "lowBatteryThreshold")
        UserDefaults.standard.removeObject(forKey: "sidetoneOff")
        UserDefaults.standard.removeObject(forKey: "sidetoneLow")
        UserDefaults.standard.removeObject(forKey: "sidetoneMid")
        UserDefaults.standard.removeObject(forKey: "sidetoneHigh")
        UserDefaults.standard.removeObject(forKey: "sidetoneMax")
        UserDefaults.standard.removeObject(forKey: "inactiveTimeOptions")
        UserDefaults.standard.removeObject(forKey: "equalizerPresets")
        super.tearDown()
    }

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

        appDelegate.lowBatteryThreshold = 99
        XCTAssertEqual(appDelegate.lowBatteryThreshold, 30)

        appDelegate.lowBatteryThreshold = -5
        XCTAssertEqual(appDelegate.lowBatteryThreshold, 1)
    }

    func testSidetoneLevelsComeFromUserDefaultsInMenuOrder() {
        UserDefaults.standard.set(-1, forKey: "sidetoneOff")
        UserDefaults.standard.set(12, forKey: "sidetoneLow")
        UserDefaults.standard.set(34, forKey: "sidetoneMid")
        UserDefaults.standard.set(56, forKey: "sidetoneHigh")
        UserDefaults.standard.set(78, forKey: "sidetoneMax")

        let appDelegate = AppDelegate()
        let levels = appDelegate.sidetoneLevelsFromSettings

        XCTAssertEqual(levels.map { $0.0 }, [
            localized("Off"),
            localized("Low"),
            localized("Medium"),
            localized("High"),
            localized("Maximum")
        ])
        XCTAssertEqual(levels.map { $0.1 }, [-1, 12, 34, 56, 78])
    }

    func testNoDevicesMenuStillProvidesSettingsAndQuitActions() {
        let appDelegate = AppDelegate()
        appDelegate.latestDevices = []
        let menu = NSMenu()

        appDelegate.menuNeedsUpdate(menu)

        XCTAssertEqual(menu.items.map { $0.title }, [
            localized("No devices found"),
            "",
            localized("Settings..."),
            localized("Quit")
        ])
        XCTAssertEqual(menu.items[2].action, #selector(AppDelegate.openSettings))
        XCTAssertEqual(menu.items[3].action, #selector(NSApplication.terminate(_:)))
    }

    func testMenuFiltersAndSortsInactiveTimeOptionsFromSettings() throws {
        UserDefaults.standard.set("90, 15, 15, 999, abc, 1", forKey: "inactiveTimeOptions")
        let appDelegate = AppDelegate()
        appDelegate.latestDevices = [[
            "device": "Test Headset",
            "vendor": "Test Vendor",
            "product": "Test Product",
            "capabilities": ["CAP_INACTIVE_TIME"]
        ]]
        let menu = NSMenu()

        appDelegate.menuNeedsUpdate(menu)

        let inactiveTimeItem = try XCTUnwrap(menu.items.first { $0.title == localized("Inactive Time") })
        let submenu = try XCTUnwrap(inactiveTimeItem.submenu)
        XCTAssertEqual(submenu.items.map { $0.title }, [
            localized("Off"),
            localized("1 Minute"),
            localized("15 Minutes"),
            localized("90 Minutes")
        ])
        XCTAssertEqual(submenu.items.map { $0.representedObject as? Int }, [0, 1, 15, 90])
    }

    func testMenuUsesConfiguredEqualizerPresetNamesWhenDeviceDoesNotReportPresets() throws {
        UserDefaults.standard.set("Game, Music, Voice", forKey: "equalizerPresets")
        let appDelegate = AppDelegate()
        appDelegate.latestDevices = [[
            "device": "Test Headset",
            "vendor": "Test Vendor",
            "product": "Test Product",
            "capabilities": ["CAP_EQUALIZER_PRESET"]
        ]]
        let menu = NSMenu()

        appDelegate.menuNeedsUpdate(menu)

        let equalizerItem = try XCTUnwrap(menu.items.first { $0.title == localized("Equalizer Preset") })
        let submenu = try XCTUnwrap(equalizerItem.submenu)
        XCTAssertEqual(submenu.items.map { $0.title }, ["Game", "Music", "Voice"])
        XCTAssertEqual(submenu.items.map { $0.representedObject as? Int }, [0, 1, 2])
    }

    func testMenuFormatsBatteryTimeToEmptyWithoutRoundingUp() {
        let appDelegate = AppDelegate()
        appDelegate.latestDevices = [[
            "device": "Test Headset",
            "vendor": "Test Vendor",
            "product": "Test Product",
            "battery": [
                "status": "BATTERY_AVAILABLE",
                "level": 44,
                "time_to_empty_min": 119
            ],
            "capabilities": []
        ]]
        let menu = NSMenu()

        appDelegate.menuNeedsUpdate(menu)

        let hoursText = String(format: localized("%dh"), 1)
        XCTAssertTrue(menu.items.contains { $0.title == "\(localized("Battery")): 44% (\(hoursText))" })
    }

    func testMockProviderReturnsMenuCapabilitiesAndClampedBatteryLevel() throws {
        let lowIndexProvider = MockHeadsetControlService(deviceIndex: 0)
        let highIndexProvider = MockHeadsetControlService(deviceIndex: 20)

        let lowBattery = try XCTUnwrap(lowIndexProvider.fetchDevices().first?["battery"] as? [String: Any])
        let highBattery = try XCTUnwrap(highIndexProvider.fetchDevices().first?["battery"] as? [String: Any])
        let capabilities = try XCTUnwrap(lowIndexProvider.fetchDevices().first?["capabilities"] as? [String])

        XCTAssertEqual(lowBattery["level"] as? Int, 5)
        XCTAssertEqual(highBattery["level"] as? Int, 95)
        XCTAssertEqual(capabilities, HeadsetCapability.menuCapabilities.map { $0.legacyCapabilityString })
    }

    func testKnownCapabilitiesExposeLegacyMenuStrings() {
        XCTAssertEqual(HeadsetCapability.sidetone.legacyCapabilityString, "CAP_SIDETONE")
        XCTAssertEqual(HeadsetCapability.lights.legacyCapabilityString, "CAP_LIGHTS")
        XCTAssertEqual(HeadsetCapability.inactiveTime.legacyCapabilityString, "CAP_INACTIVE_TIME")
        XCTAssertEqual(HeadsetCapability.voicePrompts.legacyCapabilityString, "CAP_VOICE_PROMPTS")
        XCTAssertEqual(HeadsetCapability.rotateToMute.legacyCapabilityString, "CAP_ROTATE_TO_MUTE")
        XCTAssertEqual(HeadsetCapability.equalizerPreset.legacyCapabilityString, "CAP_EQUALIZER_PRESET")
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
