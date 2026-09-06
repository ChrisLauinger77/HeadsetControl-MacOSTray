import XCTest
@testable import HeadsetControl_MacOSTray

final class NativeHeadsetResultsTests: XCTestCase {
    func testInstalledLibraryBatteryProfilesAndOrderedPresetMetadata() async {
        let done = expectation(description: "native profile transactions finish")
        HeadsetIOWorker.shared.enqueue {
            let service = HeadsetControlService()
            for (profile, code) in [(1, Int32(-5)), (4, -3), (5, -4)] {
                let device = service.fetchDevices(testProfile: profile).successValue?.first
                XCTAssertEqual(device?.battery?.failureValue?.kind, .native(code))
                if profile == 1 { XCTAssertEqual(device?.chatmix?.failureValue?.kind, .native(-5)) }
            }
            let charging = service.fetchDevices(testProfile: 2).successValue?.first
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
