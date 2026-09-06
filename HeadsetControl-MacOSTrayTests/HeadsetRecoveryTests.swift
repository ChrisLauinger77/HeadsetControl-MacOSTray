import XCTest
@testable import HeadsetControl_MacOSTray

@MainActor final class HeadsetRecoveryTests: XCTestCase {
    @MainActor private final class Fixture {
        let clock = HeadsetTestClock()
        let provider = RecordingHeadsetProvider()
        let executor = ManualHeadsetExecutor()
        let scheduler: ManualHeadsetScheduler
        let controller: HeadsetController
        init(refreshInterval: Int = 60) {
            scheduler = ManualHeadsetScheduler(clock: clock)
            let clock = self.clock
            controller = HeadsetController(provider: provider, executor: executor, scheduler: scheduler, now: { clock.now },
                                           refreshInterval: refreshInterval)
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
        f.scheduler.advance(by: 120)
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
        let f = Fixture(refreshInterval: 3600)
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
        f.scheduler.advance(by: 90)
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
        f.provider.onFetch = { f.clock.now.addTimeInterval(130) }
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

    func testSleepDropsCoalescedRecoveryBeforeCompletingOldRefresh() async {
        for completionAlreadyQueued in [false, true] {
            let f = Fixture()
            f.provider.devices = [headset()]
            f.controller.refresh(testProfile: 7)
            f.controller.recover(testProfile: 7)
            f.scheduler.advance(by: 0.75) // Recovery is now coalesced behind the first refresh.
            if completionAlreadyQueued { f.executor.runNext() }
            f.controller.invalidateSnapshot()
            if !completionAlreadyQueued { f.executor.runNext() }
            await withCheckedContinuation { continuation in HeadsetMainRunLoop.perform { continuation.resume() } }
            XCTAssertTrue(f.executor.jobs.isEmpty)
            // Expose an illicit followup's publication as well as its enqueue.
            if !f.executor.jobs.isEmpty { await f.finishRefresh() }
            XCTAssertNil(f.controller.snapshot.observedAt)
            XCTAssertEqual(f.provider.profiles, [7])
            XCTAssertTrue(f.scheduler.pending.isEmpty)

            f.controller.recover(testProfile: 7)
            f.scheduler.advance(by: 0.75)
            await f.finishRefresh()
            XCTAssertEqual(f.controller.snapshotState, .fresh)
            XCTAssertEqual(f.provider.profiles, [7, 7])
            f.controller.stop()
            f.executor.finishStop()
        }
    }

    func testRefreshRequestedAfterInvalidationBoundaryStillCoalesces() async {
        let f = Fixture()
        f.provider.devices = [headset()]
        f.controller.refresh(testProfile: 7)
        f.controller.refresh(testProfile: 7)
        // Callback code can request new work before invalidation returns.
        f.controller.onSnapshotInvalidated = {
            for _ in 0..<20 { f.controller.refresh(testProfile: 7) }
        }
        f.controller.invalidateSnapshot()
        await f.finishRefresh()
        XCTAssertNil(f.controller.snapshot.observedAt)
        await f.finishRefresh()
        XCTAssertEqual(f.controller.snapshotState, .fresh)
        XCTAssertEqual(f.provider.profiles, [7, 7])
        XCTAssertTrue(f.executor.jobs.isEmpty)
        f.controller.stop()
        f.executor.finishStop()
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

    func testIntervalIncreaseReschedulesFromObservationAndRejectsOldExpiration() async throws {
        let f = Fixture()
        f.provider.devices = [headset()]
        var invalidations = 0
        f.controller.onSnapshotInvalidated = { invalidations += 1 }
        f.controller.refresh(testProfile: 7)
        await f.finishRefresh()
        let observedAt = try XCTUnwrap(f.controller.snapshot.observedAt)
        let oldTimer = try XCTUnwrap(f.scheduler.pending.first)
        f.scheduler.advance(by: 100)
        f.controller.updateRefreshInterval(900)
        XCTAssertTrue(oldTimer.canceled)
        XCTAssertEqual(f.scheduler.pending.first?.deadline, observedAt.addingTimeInterval(960))
        f.scheduler.advance(by: 20)
        oldTimer.action() // A canceled old deadline must not invalidate the new window.
        XCTAssertEqual(invalidations, 0)
        XCTAssertEqual(f.controller.snapshotState, .fresh)
        f.scheduler.advance(by: 839)
        XCTAssertEqual(f.controller.snapshotState, .fresh)
        f.scheduler.advance(by: 1)
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(f.controller.snapshotState, .stale)
        XCTAssertTrue(f.executor.jobs.isEmpty)
    }

    func testIntervalIncreaseRestoresAgeExpiredCacheWithoutFetching() async throws {
        let f = Fixture()
        f.provider.devices = [headset()]
        f.controller.refresh(testProfile: 7)
        await f.finishRefresh()
        let observedAt = try XCTUnwrap(f.controller.snapshot.observedAt)
        f.scheduler.advance(by: 200)
        XCTAssertEqual(f.controller.snapshotState, .stale)
        f.controller.updateRefreshInterval(900)
        XCTAssertEqual(f.controller.snapshotState, .fresh)
        XCTAssertEqual(f.scheduler.pending.first?.deadline, observedAt.addingTimeInterval(960))
        f.controller.refreshIfNeeded(testProfile: 7)
        XCTAssertTrue(f.executor.jobs.isEmpty)
        XCTAssertEqual(f.provider.profiles, [7])
    }

    func testIntervalDecreaseExpiresImmediatelyOrSchedulesOnlyRemainingAge() async throws {
        for age: TimeInterval in [100, 200] {
            let f = Fixture(refreshInterval: 900)
            f.provider.devices = [headset()]
            var invalidations = 0
            f.controller.onSnapshotInvalidated = { invalidations += 1 }
            f.controller.refresh(testProfile: 7)
            await f.finishRefresh()
            let observedAt = try XCTUnwrap(f.controller.snapshot.observedAt)
            let oldTimer = try XCTUnwrap(f.scheduler.pending.first)
            f.scheduler.advance(by: age)
            f.controller.updateRefreshInterval(60)
            XCTAssertTrue(oldTimer.canceled)
            if age == 100 {
                XCTAssertEqual(f.controller.snapshotState, .fresh)
                XCTAssertEqual(f.scheduler.pending.first?.deadline, observedAt.addingTimeInterval(120))
                f.scheduler.advance(by: 20)
            }
            XCTAssertEqual(f.controller.snapshotState, .stale)
            XCTAssertEqual(invalidations, 1)
            XCTAssertTrue(f.scheduler.pending.isEmpty)
            oldTimer.action()
            XCTAssertEqual(invalidations, 1)
            XCTAssertTrue(f.executor.jobs.isEmpty)
        }
    }

    func testIntervalChangesCannotRevalidateFailureOrLifecycleInvalidation() async {
        for failed in [false, true] {
            let f = Fixture(refreshInterval: 900)
            f.provider.devices = [headset()]
            f.controller.refresh(testProfile: 7)
            await f.finishRefresh()
            if failed {
                f.provider.fetchFailure = .init(operation: .discovery, kind: .native(-5))
                f.controller.refresh(testProfile: 7)
                await f.finishRefresh()
            } else { f.controller.invalidateSnapshot() }
            for interval in [3600, 60, 900] {
                f.controller.updateRefreshInterval(interval)
                XCTAssertEqual(f.controller.snapshotState, failed ? .failed : .stale)
                XCTAssertEqual(f.controller.snapshot.devices?.count, 1)
                XCTAssertTrue(f.scheduler.pending.isEmpty)
                XCTAssertTrue(f.executor.jobs.isEmpty)
            }
        }
    }

    func testIntervalChangedDuringObservationAppliesAtPublication() async throws {
        let f = Fixture(refreshInterval: 900)
        f.provider.devices = [headset()]
        let observedAt = f.clock.now
        f.provider.onFetch = { f.clock.now.addTimeInterval(100) }
        f.controller.refresh(testProfile: 7)
        f.executor.runNext() // Native work finished; main-actor publication is still queued.
        f.controller.updateRefreshInterval(60)
        await withCheckedContinuation { continuation in HeadsetMainRunLoop.perform { continuation.resume() } }
        XCTAssertEqual(f.controller.snapshot.observedAt, observedAt)
        XCTAssertEqual(f.scheduler.pending.first?.deadline, observedAt.addingTimeInterval(120))
        XCTAssertEqual(f.controller.snapshotState, .fresh)
        f.scheduler.advance(by: 20)
        XCTAssertEqual(f.controller.snapshotState, .stale)
        XCTAssertTrue(f.executor.jobs.isEmpty)
    }

    func testStopRejectsIntervalChangesAndTheirCanceledTimers() async throws {
        let f = Fixture()
        f.provider.devices = [headset()]
        f.controller.refresh(testProfile: 7)
        await f.finishRefresh()
        let oldTimer = try XCTUnwrap(f.scheduler.pending.first)
        f.controller.stop()
        f.controller.updateRefreshInterval(3600)
        oldTimer.action()
        XCTAssertEqual(f.controller.snapshotState, .unobserved)
        XCTAssertTrue(f.scheduler.pending.isEmpty)
        XCTAssertTrue(f.executor.jobs.isEmpty)
        f.executor.finishStop()
    }

    private func headset(attachment: UInt64? = nil) -> HeadsetDevice {
        HeadsetDevice(usbID: .init(vendor: 1, product: 2), name: "Fake", vendor: "Vendor", product: "Product", capabilities: [],
                      battery: .success(.init(level: 80, status: .available)),
                      target: attachment.map { .physical(.init(vendor: 1, product: 2), attachmentID: $0) } ?? .test(profile: 7))
    }
}
