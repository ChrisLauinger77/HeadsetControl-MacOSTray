import XCTest
@testable import HeadsetControl_MacOSTray

@MainActor final class HeadsetRecoveryTests: XCTestCase {
    @MainActor private final class Fixture {
        let clock = HeadsetTestClock()
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let scheduler: ManualHeadsetScheduler
        let controller: HeadsetController
        init() {
            scheduler = ManualHeadsetScheduler(clock: clock)
            let clock = self.clock
            controller = HeadsetController(provider: provider, executor: executor, scheduler: scheduler, now: { clock.now })
        }
        func finishRefresh() async {
            XCTAssertEqual(executor.jobs.count, 1)
            guard !executor.jobs.isEmpty else { return }
            executor.runNext()
            await withCheckedContinuation { continuation in HeadsetMainRunLoop.perform { continuation.resume() } }
        }
    }

    func testStaleMenuRequestsOneRefreshAndRetainsCachedSnapshot() async {
        let f = Fixture()
        f.provider.devices = [headset()]
        f.controller.refresh(testProfile: 7)
        await f.finishRefresh()
        f.controller.refreshIfNeeded(testProfile: 7)
        XCTAssertTrue(f.executor.jobs.isEmpty)
        f.scheduler.advance(by: 60)
        XCTAssertEqual(f.controller.snapshotState, .stale)
        for _ in 0..<20 { f.controller.refreshIfNeeded(testProfile: 7) }
        XCTAssertEqual(f.controller.snapshot.devices?.first?.name, "Fake")
        await f.finishRefresh()
        XCTAssertTrue(f.executor.jobs.isEmpty)
        XCTAssertEqual(f.provider.profiles, [7, 7])
        XCTAssertEqual(f.controller.snapshotState, .fresh)
    }

    func testLifecycleBurstDiscardsPreEventResultAndCoalescesWithPolling() async {
        let f = Fixture()
        f.provider.devices = [headset()]
        f.controller.refresh(testProfile: 7)
        f.executor.runNext() // Native work finished, publication is queued.
        for _ in 0..<20 { f.controller.recover(testProfile: 7) }
        f.scheduler.advance(by: 0.75)
        f.controller.refresh(testProfile: 7)
        await withCheckedContinuation { continuation in HeadsetMainRunLoop.perform { continuation.resume() } }
        XCTAssertNil(f.controller.snapshot.observedAt)
        await f.finishRefresh()
        XCTAssertEqual(f.provider.profiles, [7, 7])
        XCTAssertEqual(f.controller.snapshotState, .fresh)
        f.scheduler.advance(by: 20)
        XCTAssertTrue(f.executor.jobs.isEmpty)
    }

    func testWakeRetriesEmptyFailureAndDelayedAvailability() async {
        let f = Fixture()
        f.controller.recover(testProfile: 7)
        f.scheduler.advance(by: 0.75)
        await f.finishRefresh()
        XCTAssertEqual(f.controller.snapshotState, .empty)
        f.provider.fetchFailure = .init(operation: .discovery, kind: .native(-5))
        f.scheduler.advance(by: 2)
        await f.finishRefresh()
        XCTAssertEqual(f.controller.snapshotState, .failed)
        f.provider.fetchFailure = nil
        f.provider.devices = [headset()]
        f.scheduler.advance(by: 5)
        await f.finishRefresh()
        XCTAssertEqual(f.controller.snapshotState, .fresh)
        f.scheduler.advance(by: 10)
        XCTAssertEqual(f.provider.profiles.count, 3)
        XCTAssertTrue(f.executor.jobs.isEmpty)
    }

    func testRetriesAreBoundedAndFreshEmptyMenuDoesNotRestartThem() async {
        let f = Fixture()
        f.controller.recover(testProfile: 7)
        for delay in [0.75, 2, 5, 10] {
            f.scheduler.advance(by: delay)
            await f.finishRefresh()
        }
        f.scheduler.advance(by: 30)
        f.controller.refreshIfNeeded(testProfile: 7)
        XCTAssertEqual(f.provider.profiles.count, 4)
        XCTAssertTrue(f.executor.jobs.isEmpty)
        XCTAssertEqual(f.controller.snapshotState, .empty)
        f.scheduler.advance(by: 30)
        f.controller.refreshIfNeeded(testProfile: 7)
        XCTAssertEqual(f.executor.jobs.count, 1) // A later stale menu remains a recovery path.
    }

    func testDisconnectClearsSnapshotAndReconnectUsesNewAttachment() async {
        let f = Fixture()
        f.provider.devices = [headset(attachment: 11)]
        f.controller.refresh(testProfile: 0)
        await f.finishRefresh()
        f.controller.recover(testProfile: 0)
        XCTAssertEqual(f.controller.snapshotState, .stale)
        f.provider.devices = []
        f.scheduler.advance(by: 0.75)
        await f.finishRefresh()
        XCTAssertEqual(f.controller.snapshotState, .empty)
        f.provider.devices = [headset(attachment: 12)]
        f.controller.recover(testProfile: 0)
        f.scheduler.advance(by: 0.75)
        await f.finishRefresh()
        XCTAssertEqual(f.controller.snapshot.devices?.first?.target, .physical(.init(vendor: 1, product: 2), attachmentID: 12))
        XCTAssertTrue(f.executor.jobs.isEmpty)
    }

    func testStopCancelsRecoveryExpirationAndLateCallbacks() async {
        let f = Fixture()
        f.provider.devices = [headset()]
        f.controller.refresh(testProfile: 7)
        await f.finishRefresh()
        f.controller.recover(testProfile: 7)
        let callbacks = f.scheduler.tasks.map(\.action)
        f.scheduler.advance(by: 0.75)
        f.executor.runNext()
        f.controller.refresh(testProfile: 7) // One coalesced followup.
        f.controller.stop()
        var changes = 0
        f.controller.onRefresh = { _ in changes += 1 }
        f.controller.onSnapshotInvalidated = { changes += 1 }
        callbacks.forEach { $0() }
        f.controller.recover(testProfile: 7)
        f.controller.refreshIfNeeded(testProfile: 7)
        await withCheckedContinuation { continuation in HeadsetMainRunLoop.perform { continuation.resume() } }
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(f.executor.jobs.isEmpty)
        XCTAssertTrue(f.scheduler.pending.isEmpty)
        f.executor.finishStop()
    }

    func testObservationTimeDoesNotBecomePublicationTimeAfterLongTransaction() async {
        let f = Fixture()
        f.provider.devices = [headset()]
        let started = f.clock.now
        f.provider.onFetch = { f.clock.now.addTimeInterval(70) }
        f.controller.refresh(testProfile: 7)
        await f.finishRefresh()
        XCTAssertEqual(f.controller.snapshot.observedAt, started)
        XCTAssertEqual(f.controller.snapshotState, .stale)
    }

    func testModeSwitchCancelsPhysicalRecoveryAndRejectsItsLateTimer() async throws {
        let f = Fixture()
        f.controller.recover(testProfile: 0)
        let timer = try XCTUnwrap(f.scheduler.pending.first)
        f.provider.devices = [headset()]
        f.controller.refresh(testProfile: 7)
        timer.action()
        await f.finishRefresh()
        XCTAssertEqual(f.provider.profiles, [7])
        XCTAssertTrue(f.executor.jobs.isEmpty)
    }

    func testSleepCancelsRetriesAndRejectsPreSleepResultsUntilResume() async throws {
        let f = Fixture()
        f.controller.recover(testProfile: 7)
        let timer = try XCTUnwrap(f.scheduler.pending.first)
        f.scheduler.advance(by: 0.75)
        f.executor.runNext()
        f.controller.invalidateSnapshot()
        timer.action()
        await withCheckedContinuation { continuation in HeadsetMainRunLoop.perform { continuation.resume() } }
        XCTAssertNil(f.controller.snapshot.observedAt)
        XCTAssertTrue(f.scheduler.pending.isEmpty)
        XCTAssertTrue(f.executor.jobs.isEmpty)
        f.provider.devices = [headset()]
        f.controller.recover(testProfile: 7)
        f.scheduler.advance(by: 0.75)
        await f.finishRefresh()
        XCTAssertEqual(f.controller.snapshotState, .fresh)
    }

    func testWakeRetriesUnreadyTelemetryEvenWhenReceiverIsDiscoverable() async {
        let f = Fixture()
        var device = headset()
        device.battery = .success(.init(level: 0, status: .unavailable))
        f.provider.devices = [device]
        f.controller.recover(testProfile: 7)
        f.scheduler.advance(by: 0.75)
        await f.finishRefresh()
        f.provider.devices[0].battery = .failure(.init(operation: .battery, kind: .native(-4)))
        f.scheduler.advance(by: 2)
        await f.finishRefresh()
        f.provider.devices[0].battery = .success(.init(level: -1, status: .charging))
        f.scheduler.advance(by: 5)
        await f.finishRefresh()
        f.scheduler.advance(by: 10)
        XCTAssertEqual(f.provider.profiles.count, 3)
        XCTAssertTrue(f.executor.jobs.isEmpty)
    }

    private func headset(attachment: UInt64? = nil) -> HeadsetDevice {
        HeadsetDevice(usbID: .init(vendor: 1, product: 2), name: "Fake", vendor: "Vendor", product: "Product", capabilities: [],
                      battery: .success(.init(level: 80, status: .available)),
                      target: attachment.map { .physical(.init(vendor: 1, product: 2), attachmentID: $0) } ?? .test(profile: 7))
    }
}
