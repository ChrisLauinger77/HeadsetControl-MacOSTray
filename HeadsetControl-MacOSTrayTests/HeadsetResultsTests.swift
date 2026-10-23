import XCTest
import HeadsetControlCLib
@testable import HeadsetControl_MacOSTray

extension Result {
    var successValue: Success? { if case .success(let value) = self { return value }; return nil }
    var failureValue: Failure? { if case .failure(let error) = self { return error }; return nil }
    var isSuccess: Bool { if case .success = self { return true }; return false }
}

final class HeadsetResultsTests: XCTestCase {
    func testBatteryContractDoesNotConfuseUnavailableWithZeroPercent() throws {
        let unavailable = try HeadsetBattery.decode(level: 0, rawStatus: Int(HSC_BATTERY_UNAVAILABLE.rawValue)).get()
        XCTAssertEqual(unavailable.status, .unavailable)
        XCTAssertNil(unavailable.percentage)
        XCTAssertNil(unavailable.chargeText)
        let empty = try HeadsetBattery.decode(level: 0, rawStatus: Int(HSC_BATTERY_AVAILABLE.rawValue)).get()
        XCTAssertEqual(empty.percentage, 0)
        XCTAssertEqual(empty.chargeText, "0%")
        let low = try HeadsetBattery.decode(level: 10, rawStatus: Int(HSC_BATTERY_AVAILABLE.rawValue)).get()
        XCTAssertEqual(low.percentage, 10)
        XCTAssertEqual(low.status, .available)
    }

    func testChargingUnknownAndMalformedMeasurements() throws {
        XCTAssertEqual(try HeadsetBattery.decode(level: 50, rawStatus: Int(HSC_BATTERY_CHARGING.rawValue)).get().chargeText, "⚡︎ 50%")
        XCTAssertEqual(try HeadsetBattery.decode(level: -1, rawStatus: Int(HSC_BATTERY_CHARGING.rawValue)).get().chargeText, "⚡︎")
        for level in [-100, -1, 101, Int.max] {
            XCTAssertFalse(HeadsetBattery.decode(level: level, rawStatus: Int(HSC_BATTERY_AVAILABLE.rawValue)).isSuccess)
            XCTAssertNil(HeadsetBattery(level: level, status: .available).percentage)
            XCTAssertNil(HeadsetBattery(level: level, status: .charging).percentage)
        }
        XCTAssertFalse(HeadsetBattery.decode(level: 101, rawStatus: Int(HSC_BATTERY_CHARGING.rawValue)).isSuccess)
        for raw in [-101, -2, -1, 42] {
            XCTAssertNil(try HeadsetBattery.decode(level: 10, rawStatus: raw).get().percentage)
        }
        for status in [HSC_BATTERY_ERROR, HSC_BATTERY_TIMEOUT] {
            let rawStatus = Int(status.rawValue)
            XCTAssertEqual(HeadsetBattery.decode(level: 0, rawStatus: rawStatus).failureValue?.kind, .batteryStatus(rawStatus))
        }
    }

    func testSidetoneMatchesOnlyAnExactConfiguredPreset() throws {
        let levels = [0, 32, 64, 96, 128]
        let exact = try HeadsetSidetone.decode(level: 64, deviceLevel: 2, deviceMin: 0, deviceMax: 4, levelName: nil).get()
        XCTAssertEqual(exact.matchingPresetIndex(in: levels), 2)
        let between = try HeadsetSidetone.decode(level: 85, deviceLevel: 2, deviceMin: 0, deviceMax: 3, levelName: "Medium").get()
        XCTAssertNil(between.matchingPresetIndex(in: levels))
        XCTAssertEqual(between.matchingPresetIndex(in: [0, 85, 85, 128]), 1)
        XCTAssertNil(exact.matchingPresetIndex(in: [-1, 32, 96]))
    }

    func testSidetoneDecodesOptionalNamesAndRejectsMalformedLevels() throws {
        let named = try HeadsetSidetone.decode(level: 85, deviceLevel: 2, deviceMin: 0, deviceMax: 3, levelName: " Medium ").get()
        XCTAssertEqual(named.levelName, "Medium")
        XCTAssertEqual(named.deviceLevel, 2)
        XCTAssertEqual(named.deviceMin, 0)
        XCTAssertEqual(named.deviceMax, 3)
        for name in [nil, "", " \n "] as [String?] {
            XCTAssertNil(try HeadsetSidetone.decode(level: 0, deviceLevel: 0, deviceMin: 0, deviceMax: 3, levelName: name).get().levelName)
        }
        for level in [-1, 129] {
            XCTAssertFalse(HeadsetSidetone.decode(level: level, deviceLevel: 0, deviceMin: 0, deviceMax: 3, levelName: nil).isSuccess)
        }
        XCTAssertFalse(HeadsetSidetone.decode(level: 64, deviceLevel: 4, deviceMin: 0, deviceMax: 3, levelName: nil).isSuccess)
        XCTAssertFalse(HeadsetSidetone.decode(level: 64, deviceLevel: 0, deviceMin: 3, deviceMax: 0, levelName: nil).isSuccess)
    }

    func testPresetNamesKeepNativeIndicesIncludingMissingAndDuplicateNames() throws {
        let names: [String?] = ["Flat", nil, "Flat", " Voice "]
        let presets = try HeadsetEqualizerPreset.read(count: 4) { names[$0] }.get()
        XCTAssertEqual(presets.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(presets.map(\.name), ["Flat", nil, "Flat", "Voice"])
        XCTAssertTrue(try HeadsetEqualizerPreset.read(count: 0) { _ in XCTFail(); return nil }.get().isEmpty)
        XCTAssertFalse(HeadsetEqualizerPreset.read(count: -1) { _ in XCTFail(); return nil }.isSuccess)
        XCTAssertFalse(HeadsetEqualizerPreset.read(count: 256) { _ in XCTFail(); return nil }.isSuccess)
    }

    func testNativeErrorKeepsOperationAndExactCode() {
        let result = HeadsetFailure.result(code: -1234, operation: .command)
        XCTAssertEqual(result.failureValue, HeadsetFailure(operation: .command, kind: .native(-1234)))
        XCTAssertTrue(result.failureValue?.message.contains("-1234") == true)
    }
}
