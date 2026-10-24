import AppKit
import SwiftUI
import XCTest
@testable import HeadsetControl_MacOSTray

final class LightColorTests: XCTestCase {
    func testPackedColorRoundTripsAndClampsOutOfRangeValues() {
        let color = HeadsetLightColor(rgb: 0x12AB3F)
        XCTAssertEqual([color.red, color.green, color.blue], [0x12, 0xAB, 0x3F])
        XCTAssertEqual(color.rgb, 0x12AB3F)
        XCTAssertEqual(color.hexString, "#12AB3F")
        XCTAssertEqual(HeadsetLightColor(rgb: 0).hexString, "#000000")
        XCTAssertEqual(HeadsetLightColor(rgb: -1).rgb, 0)
        XCTAssertEqual(HeadsetLightColor(rgb: Int.min).rgb, 0)
        XCTAssertEqual(HeadsetLightColor(rgb: Int.max).rgb, 0xFFFFFF)
    }

    func testDefaultsRepairInvalidValuesToTheirPresetAndKeepBlack() throws {
        let name = "LightColors.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        AppDefaults.register(in: store)
        XCTAssertEqual(AppDefaults.lightColorKeys.map { store.integer(forKey: $0) }, [0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF])
        store.set(0, forKey: "lightColor1")
        store.set(0x123456, forKey: "lightColor2")
        AppDefaults.validate(in: store)
        XCTAssertEqual(store.integer(forKey: "lightColor1"), 0)
        XCTAssertEqual(store.integer(forKey: "lightColor2"), 0x123456)
        for invalid: Any in [-1, 0x1000000, Int.max, 1.5, "invalid", true] {
            store.set(invalid, forKey: "lightColor3")
            AppDefaults.validate(in: store)
            XCTAssertEqual(store.integer(forKey: "lightColor3"), 0x00FF00, "\(invalid)")
        }
        for invalid: Any? in [nil, Double.nan, Double.infinity] {
            XCTAssertEqual(AppDefaults.validatedLightColor(invalid, fallback: 0x0000FF), 0x0000FF)
        }
    }

    @MainActor func testColorPanelColorsBecomeSRGBBytes() throws {
        for rgb in [0x000000, 0xFFFFFF, 0xFF0000, 0x12AB3F] {
            let color = HeadsetLightColor(rgb: rgb)
            XCTAssertEqual(HeadsetLightColor(nsColor: color.nsColor), color)
        }
        // Display P3 red is outside sRGB; it must still map to valid bytes.
        let p3Red = try XCTUnwrap(HeadsetLightColor(nsColor: NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)))
        XCTAssertEqual(p3Red.red, 0xFF)
        XCTAssertNil(HeadsetLightColor(nsColor: NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))))
    }

    @MainActor func testSettingsPickerStoresPackedColorsAndReadsRepairedPresets() {
        let store = AppDefaults.standard
        defer { AppDefaults.lightColorKeys.forEach { store.removeObject(forKey: $0) } }
        let view = LightColorSettingsView()
        view.colorBinding(1).wrappedValue = Color(nsColor: HeadsetLightColor(rgb: 0x12AB3F).nsColor)
        XCTAssertEqual(store.integer(forKey: "lightColor2"), 0x12AB3F)
        XCTAssertEqual(view.preset(1).hexString, "#12AB3F")
        // Launch repairs stored values before any @AppStorage read.
        store.set("invalid", forKey: "lightColor3")
        AppDefaults.validate(in: store)
        XCTAssertEqual(view.preset(2), HeadsetLightColor(rgb: 0x00FF00))
        view.colorBinding(0).wrappedValue = .black
        XCTAssertEqual(store.integer(forKey: "lightColor1"), 0)
    }
}
