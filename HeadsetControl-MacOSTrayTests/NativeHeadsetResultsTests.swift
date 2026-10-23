import XCTest
import HeadsetControlCLib
@testable import HeadsetControl_MacOSTray

final class NativeHeadsetResultsTests: XCTestCase {
    private func verifyNativeWrites(_ commands: [HeadsetCommand], profileOneFails: Bool = false) async {
        let done = expectation(description: "native write profiles finish")
        HeadsetIOWorker.shared.enqueue {
            let service = HeadsetControlService()
            for command in commands {
                XCTAssertTrue(service.perform(command, on: .test(profile: 7), testProfile: 7).isSuccess, "\(command)")
                let result = service.perform(command, on: .test(profile: 1), testProfile: 1)
                if profileOneFails { XCTAssertEqual(result.failureValue?.kind, .native(-5), "\(command)") }
                else { XCTAssertTrue(result.isSuccess, "Upstream profile 1 also succeeds for \(command)") }
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
    }

    func testNativeMicrophoneVolumeClampsBeforeCallingTheLibrary() async {
        await verifyNativeWrites([Int.min, -1, 0, 64, 128, 129, Int.max].map(HeadsetCommand.microphoneVolume))
    }

    func testSidetoneReadbackCopiesNamedLevelAndKeepsDeviceOnFailure() async throws {
        let service = HeadsetControlService()
        let result = await withCheckedContinuation { continuation in
            HeadsetIOWorker.shared.enqueue {
                let success = service.fetchDevices(testProfile: 7)
                let failure = service.fetchDevices(testProfile: 1)
                continuation.resume(returning: (success, failure))
            }
        }
        let device = try XCTUnwrap(result.0.get().first)
        let status = try XCTUnwrap(device.sidetone).get()
        XCTAssertEqual(status.level, 85)
        XCTAssertEqual(status.deviceLevel, 2)
        XCTAssertEqual(status.deviceMin, 0)
        XCTAssertEqual(status.deviceMax, 3)
        XCTAssertEqual(status.levelName, "Medium") // Still owned after another query and both releases.
        XCTAssertEqual(device.battery?.successValue?.percentage, 10)
        let failed = try XCTUnwrap(result.1.get().first)
        let error = HeadsetFailure(operation: .sidetone, kind: .native(-5))
        XCTAssertEqual(failed.sidetone?.failureValue, error)
        XCTAssertTrue(failed.failures.contains(error))
        XCTAssertEqual(failed.equalizerPresets?.successValue?.count, 4)
        XCTAssertTrue(failed.capabilities.contains("CAP_SIDETONE"))
    }

    func testInstalledLibraryBatteryProfilesAndOrderedPresetMetadata() async {
        XCTAssertEqual(HSC_BATTERY_UNAVAILABLE.rawValue, 0)
        XCTAssertEqual(HSC_BATTERY_CHARGING.rawValue, 1)
        XCTAssertEqual(HSC_BATTERY_AVAILABLE.rawValue, 2)
        XCTAssertEqual(HSC_BATTERY_ERROR.rawValue, 3)
        XCTAssertEqual(HSC_BATTERY_TIMEOUT.rawValue, 4)
        let done = expectation(description: "native profile transactions finish")
        HeadsetIOWorker.shared.enqueue {
            let service = HeadsetControlService()
            for (profile, code) in [(1, Int32(-5)), (4, -3), (5, -4)] {
                let device = service.fetchDevices(testProfile: profile).successValue?.first
                XCTAssertEqual(device?.battery?.failureValue?.kind, .native(code))
                if profile == 1 { XCTAssertEqual(device?.chatmix?.failureValue?.kind, .native(-5)) }
            }
            let charging = service.fetchDevices(testProfile: 2).successValue?.first
            XCTAssertEqual(charging?.battery?.successValue?.status, .charging)
            XCTAssertEqual(charging?.battery?.successValue?.percentage, 50)
            XCTAssertEqual(charging?.battery?.successValue?.chargeText, "⚡︎ 50%")
            let low = service.fetchDevices(testProfile: 7).successValue?.first
            XCTAssertEqual(low?.battery?.successValue?.percentage, 10)
            XCTAssertEqual(low?.battery?.successValue?.status, .available)
            XCTAssertEqual(low?.equalizerPresets?.successValue?.map(\.index), [0, 1, 2, 3])
            XCTAssertEqual(low?.equalizerPresets?.successValue?.map(\.name), ["Flat", "Bass Boost", "Treble Boost", "V-Shape"])
            XCTAssertEqual(service.perform(.sidetone(32), on: .test(profile: 1), testProfile: 1).failureValue?.kind, .native(-5))
            for index in [-1, 4, Int.max] {
                XCTAssertEqual(service.perform(.equalizerPreset(index), on: .test(profile: 7), testProfile: 7).failureValue?.kind, .unsupportedPreset(index))
            }
            do {
                try NativeHeadsetLibrary().configure(testProfile: Int.max)
                XCTFail("Invalid profile must be rejected")
            } catch {
                XCTAssertEqual((error as? HeadsetFailure)?.kind, .invalidTestProfile(Int.max))
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
    }
}
