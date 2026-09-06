import XCTest
@testable import HeadsetControl_MacOSTray

final class NativeDependencyVersionsTests: XCTestCase {
    private let revision = "a6e15cc8bc701a9c4dab8ae4e33363f3040628e9"

    private func provenance(channel: String = "release", revision: String? = nil,
                            headsetControl: String = "4.1.0", hidapi: String = "0.15.0", schema: Int = 2) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema": schema,
            "headsetcontrol": ["version": headsetControl, "channel": channel, "revision": revision ?? self.revision],
            "hidapi": ["version": hidapi],
            "application_revision": String(repeating: "b", count: 40)
        ])
    }

    func testReleaseAndHIDAPIDisplayUseRuntimeValues() throws {
        let values = NativeDependencyVersions(headsetControl: "4.1.0", hidapi: "0.15.0", provenance: try provenance())
        XCTAssertEqual(values.headsetControlDisplay, "4.1.0")
        XCTAssertEqual(values.hidapiDisplay, "0.15.0")
        XCTAssertNil(values.snapshotRevision)
        XCTAssertTrue(values.diagnostics.isEmpty)
    }

    func testSnapshotUsesOnlyPinnedNativeRevisionAndLocalizedFormat() throws {
        // Neither the application revision nor any checkout participates in the suffix.
        let values = NativeDependencyVersions(headsetControl: "4.1.0", hidapi: "0.15.0", provenance: try provenance(channel: "snapshot"))
        XCTAssertEqual(values.snapshotRevision, "a6e15cc8bc70")
        XCTAssertEqual(values.headsetControlDisplay,
                       String(format: NSLocalizedString("%@ snapshot (%@)", comment: ""), "4.1.0", "a6e15cc8bc70"))
        XCTAssertFalse(values.headsetControlDisplay.contains(revision))
        XCTAssertTrue(values.diagnostics.isEmpty)
    }

    func testRuntimeMismatchIsDiagnosedAndDoesNotSubstituteExpectedVersion() throws {
        for channel in ["release", "snapshot"] {
            let values = NativeDependencyVersions(headsetControl: "4.2.0", hidapi: "0.16.0", provenance: try provenance(channel: channel))
            XCTAssertEqual(values.headsetControl, "4.2.0")
            XCTAssertEqual(values.hidapiDisplay, "0.16.0")
            XCTAssertEqual(values.diagnostics.count, 2)
            XCTAssertTrue(values.diagnostics.allSatisfy { $0.contains("differs from embedded build provenance") })
        }
    }

    func testUnavailableAndMalformedAPIVersionsFallBackSafely() throws {
        let unknown = NSLocalizedString("Unknown", comment: "")
        for invalid: String? in [nil, "", " \n", "-1", "4.1", "4.1.0 garbage", "4.1.0\n0.15.0", "0.15.0\u{0}", String(repeating: "1", count: 129)] {
            let values = NativeDependencyVersions(headsetControl: invalid, hidapi: invalid, provenance: try provenance())
            XCTAssertEqual(values.headsetControlDisplay, unknown)
            XCTAssertEqual(values.hidapiDisplay, unknown)
            XCTAssertFalse(values.diagnostics.isEmpty)
        }
        XCTAssertEqual(NativeDependencyVersions.usableVersion(" 0.15.0\n"), "0.15.0")
        XCTAssertEqual(NativeDependencyVersions.usableVersion("4.2.0-rc.1+dev"), "4.2.0-rc.1+dev")
    }

    func testMissingProvenanceDoesNotInventSnapshotIdentity() {
        let values = NativeDependencyVersions(headsetControl: "4.1.0", hidapi: "0.15.0", provenance: nil)
        XCTAssertEqual(values.headsetControlDisplay, "4.1.0")
        XCTAssertEqual(values.hidapiDisplay, "0.15.0")
        XCTAssertNil(values.snapshotRevision)
        XCTAssertEqual(values.diagnostics.count, 1)
    }

    func testInvalidProvenanceDoesNotInventSnapshotIdentity() throws {
        let fixtures = try [Data("not JSON".utf8), provenance(channel: "nightly"),
                            provenance(channel: "snapshot", revision: "HEAD"),
                            provenance(channel: "snapshot", revision: revision + "\n"),
                            provenance(headsetControl: "invalid"), provenance(schema: 99)]
        for fixture in fixtures {
            let values = NativeDependencyVersions(headsetControl: "4.1.0", hidapi: "0.15.0", provenance: fixture)
            XCTAssertNil(values.snapshotRevision)
            XCTAssertTrue(values.diagnostics.contains { $0.contains("Invalid embedded build provenance") })
        }
    }

    func testApplicationVersionAndBuildPresentationRemainUnchanged() {
        let info = ApplicationVersionInfo(info: ["CFBundleShortVersionString": "3.1.0", "CFBundleVersion": "260906.1244"])
        XCTAssertEqual(info.versionLine, "\(NSLocalizedString("Version", comment: "")): 3.1.0")
        XCTAssertEqual(info.buildLine, "\(NSLocalizedString("Build", comment: "")): 260906.1244")
        for missing: [String: Any]? in [nil, [:], ["CFBundleShortVersionString": 42, "CFBundleVersion": 42]] {
            let fallback = ApplicationVersionInfo(info: missing)
            XCTAssertEqual(fallback.version, "-")
            XCTAssertEqual(fallback.build, "-")
        }
    }

    func testLinkedVersionAPIsReturnUsableValuesWithoutDeviceDiscovery() async {
        let done = expectation(description: "native metadata read")
        HeadsetIOWorker.shared.enqueue {
            let values = HeadsetControlService.nativeVersions(provenance: nil)
            XCTAssertNotNil(values.headsetControl)
            XCTAssertNotNil(values.hidapi)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
    }

    func testLinkedVersionsMatchEmbeddedProvenance() async throws {
        // The shared build helper runs this again after stamping the actual app bundle.
        // Tests and the app link the same explicit static archives on each native runner.
        guard let path = ProcessInfo.processInfo.environment["HEADSETCONTROL_PROVENANCE_PATH"] else {
            throw XCTSkip("Requires the shared build helper's completed app bundle")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let done = expectation(description: "verify linked APIs against embedded provenance")
        HeadsetIOWorker.shared.enqueue {
            let values = HeadsetControlService.nativeVersions(provenance: data)
            XCTAssertTrue(values.diagnostics.isEmpty, values.diagnostics.joined(separator: "; "))
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
    }
}
