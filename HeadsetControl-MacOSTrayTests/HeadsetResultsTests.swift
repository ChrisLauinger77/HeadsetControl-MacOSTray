import XCTest
@testable import HeadsetControl_MacOSTray

extension Result {
    var successValue: Success? { if case .success(let value) = self { return value }; return nil }
    var failureValue: Failure? { if case .failure(let error) = self { return error }; return nil }
    var isSuccess: Bool { if case .success = self { return true }; return false }
}

final class HeadsetResultsTests: XCTestCase {
    func testBatteryContractDoesNotConfuseUnavailableWithZeroPercent() throws {
        let unavailable = try HeadsetBattery.decode(level: 0, rawStatus: 0).get()
        XCTAssertEqual(unavailable.status, .unavailable)
        XCTAssertNil(unavailable.percentage)
        XCTAssertNil(unavailable.chargeText)
        let empty = try HeadsetBattery.decode(level: 0, rawStatus: 2).get()
        XCTAssertEqual(empty.percentage, 0)
        XCTAssertEqual(empty.chargeText, "0%")
        let low = try HeadsetBattery.decode(level: 10, rawStatus: 2).get()
        XCTAssertEqual(low.percentage, 10)
        XCTAssertEqual(low.status, .available)
    }

    func testChargingUnknownAndMalformedMeasurements() throws {
        XCTAssertEqual(try HeadsetBattery.decode(level: 50, rawStatus: 1).get().chargeText, "⚡︎ 50%")
        XCTAssertEqual(try HeadsetBattery.decode(level: -1, rawStatus: 1).get().chargeText, "⚡︎")
        for level in [-100, -1, 101, Int.max] {
            XCTAssertFalse(HeadsetBattery.decode(level: level, rawStatus: 2).isSuccess)
            XCTAssertNil(HeadsetBattery(level: level, status: .available).percentage)
            XCTAssertNil(HeadsetBattery(level: level, status: .charging).percentage)
        }
        XCTAssertFalse(HeadsetBattery.decode(level: 101, rawStatus: 1).isSuccess)
        for raw in [-101, -2, -1, 42] {
            XCTAssertNil(try HeadsetBattery.decode(level: 10, rawStatus: raw).get().percentage)
        }
        XCTAssertEqual(HeadsetBattery.decode(level: 0, rawStatus: 3).failureValue?.kind, .batteryStatus(3))
        XCTAssertEqual(HeadsetBattery.decode(level: 0, rawStatus: 4).failureValue?.kind, .batteryStatus(4))
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
