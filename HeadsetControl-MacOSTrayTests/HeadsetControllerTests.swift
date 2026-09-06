import XCTest
@testable import HeadsetControl_MacOSTray

// These seams let tests hold a transaction open and deliver callbacks in a
// chosen order without touching HID or depending on timer wall-clock timing.
final class ManualHeadsetExecutor: HeadsetWorkExecuting, @unchecked Sendable {
    var jobs: [@Sendable () -> Void] = []
    var cleanup: (@Sendable () -> Void)?
    var completion: (@Sendable () -> Void)?

    func enqueue(_ work: @escaping @Sendable () -> Void) { jobs.append(work) }
    func stop(cleanup: @escaping @Sendable () -> Void, completion: @escaping @Sendable () -> Void) {
        jobs.removeAll()
        self.cleanup = cleanup
        self.completion = completion
    }
    func runNext() { jobs.removeFirst()() }
    func finishStop() { cleanup?(); completion?() }
}

final class RecordingHeadsetProvider: HeadsetControlProviding, @unchecked Sendable {
    var profiles: [Int] = []
    var commands: [(HeadsetCommand, HeadsetTarget, Int)] = []
    var shutdownCount = 0
    var onFetch: (() -> Void)?
    var devices: [HeadsetDevice] = []
    var fetchFailure: HeadsetFailure?
    var commandResult: Result<Void, HeadsetFailure> = .success(())

    func fetchDevices(testProfile: Int) -> Result<[HeadsetDevice], HeadsetFailure> {
        profiles.append(testProfile)
        onFetch?()
        return fetchFailure.map { .failure($0) } ?? .success(devices)
    }
    func perform(_ command: HeadsetCommand, on target: HeadsetTarget, testProfile: Int) -> Result<Void, HeadsetFailure> {
        commands.append((command, target, testProfile))
        return commandResult
    }
    func shutdown() { shutdownCount += 1 }
}

final class HeadsetControllerTests: XCTestCase {
    @MainActor func testOverlappingRefreshesCoalesceIntoOneFollowup() async {
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let controller = HeadsetController(provider: provider, executor: executor)
        var publications = 0
        controller.onRefresh = { _ in publications += 1 }

        controller.refresh(testProfile: 0)
        for _ in 0..<20 { controller.refresh(testProfile: 0) }
        XCTAssertEqual(executor.jobs.count, 1)
        executor.runNext()
        await drainMainQueue()
        XCTAssertEqual(executor.jobs.count, 1)
        executor.runNext()
        await drainMainQueue()
        XCTAssertEqual(provider.profiles, [0, 0])
        XCTAssertEqual(publications, 2)
        XCTAssertTrue(executor.jobs.isEmpty)
    }

    @MainActor func testReentrantTimerRequestOnlyQueuesAFollowup() async {
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let controller = HeadsetController(provider: provider, executor: executor)
        provider.onFetch = {
            MainActor.assumeIsolated { controller.refresh(testProfile: 0) }
            XCTAssertTrue(executor.jobs.isEmpty)
        }
        controller.refresh(testProfile: 0)
        executor.runNext()
        await drainMainQueue()
        XCTAssertEqual(provider.profiles, [0])
        XCTAssertEqual(executor.jobs.count, 1)
    }

    @MainActor func testCommandKeepsItsTargetAndRejectsCrossModeActions() async {
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let controller = HeadsetController(provider: provider, executor: executor)
        let target = HeadsetTarget.physical(HeadsetUSBID(vendor: 1, product: 2), attachmentID: 3)
        controller.perform(.lights(false), on: target, testProfile: 0)
        executor.runNext()
        XCTAssertEqual(provider.commands.count, 1)
        XCTAssertEqual(provider.commands.first?.1, target)
        controller.perform(.lights(false), on: target, testProfile: 7)
        controller.perform(.lights(false), on: .test(profile: 7), testProfile: 0)
        XCTAssertTrue(executor.jobs.isEmpty)
    }

    @MainActor func testStopDropsQueuedWorkAndLateResultsWithoutWaiting() async {
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let controller = HeadsetController(provider: provider, executor: executor)
        var publications = 0
        var stopped = false
        controller.onRefresh = { _ in publications += 1 }
        controller.refresh(testProfile: 0)
        executor.runNext() // Its main-actor completion is still pending.
        controller.refresh(testProfile: 0)
        controller.stop { stopped = true }
        controller.refresh(testProfile: 0)
        XCTAssertFalse(stopped)
        await drainMainQueue()
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(executor.jobs.isEmpty)
        executor.finishStop()
        await drainMainQueue()
        XCTAssertTrue(stopped)
        XCTAssertEqual(provider.shutdownCount, 1)
    }

    @MainActor func testModeChangeDiscardsOldSnapshotAndQueuedCommand() async {
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let controller = HeadsetController(provider: provider, executor: executor)
        var publications = 0
        controller.onRefresh = { _ in publications += 1 }
        controller.refresh(testProfile: 0)
        controller.perform(.lights(false), on: .physical(HeadsetUSBID(vendor: 1, product: 2), attachmentID: 3), testProfile: 0)
        controller.refresh(testProfile: 7)
        executor.runNext()
        executor.runNext()
        await drainMainQueue()
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(provider.commands.isEmpty)
        executor.runNext()
        await drainMainQueue()
        XCTAssertEqual(provider.profiles, [7])
        XCTAssertEqual(publications, 1)
    }

    @MainActor func testRefreshRequestedDuringPublicationStillCoalesces() async {
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let controller = HeadsetController(provider: provider, executor: executor)
        controller.onRefresh = { _ in
            controller.refresh(testProfile: 0)
            controller.refresh(testProfile: 0)
        }
        controller.refresh(testProfile: 0)
        controller.refresh(testProfile: 0)
        executor.runNext()
        await drainMainQueue()
        XCTAssertEqual(executor.jobs.count, 1)
        controller.onRefresh = nil
        executor.runNext()
        await drainMainQueue()
        XCTAssertTrue(executor.jobs.isEmpty)
        XCTAssertEqual(provider.profiles, [0, 0])
    }

    @MainActor func testActionModeChangeCannotRestoreAnOlderPendingProfile() async {
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let controller = HeadsetController(provider: provider, executor: executor)
        controller.refresh(testProfile: 0)
        controller.refresh(testProfile: 7)
        controller.perform(.lights(false), on: .test(profile: 6), testProfile: 6)
        executor.runNext() // Obsolete physical refresh is skipped.
        executor.runNext() // Current test command.
        await drainMainQueue()
        executor.runNext()
        await drainMainQueue()
        XCTAssertEqual(provider.profiles, [6])
        XCTAssertEqual(provider.commands.first?.2, 6)
    }

    @MainActor func testEmptyDiscoveryAndFailureStayDistinctThroughCoordinator() async {
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let controller = HeadsetController(provider: provider, executor: executor)
        var results: [Result<[HeadsetDevice], HeadsetFailure>] = []
        controller.onRefresh = { results.append($0) }
        let error = HeadsetFailure(operation: .discovery, kind: .native(-5))
        provider.fetchFailure = error
        controller.refresh(testProfile: 0)
        executor.runNext()
        await drainMainQueue()
        provider.fetchFailure = nil
        controller.refresh(testProfile: 0)
        executor.runNext()
        await drainMainQueue()
        XCTAssertEqual(results[0].failureValue, error)
        XCTAssertEqual(results[1].successValue?.count, 0)
    }

    @MainActor func testCommandErrorReachesCallerAndStopCancelsLateCompletionOnce() async {
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let controller = HeadsetController(provider: provider, executor: executor)
        let error = HeadsetFailure(operation: .command, kind: .native(-4))
        provider.commandResult = .failure(error)
        var results: [Result<Void, HeadsetFailure>] = []
        controller.perform(.lights(false), on: .test(profile: 7), testProfile: 7) { result in
            XCTAssertTrue(Thread.isMainThread)
            results.append(result)
        }
        executor.runNext()
        await drainMainQueue()
        XCTAssertEqual(results.first?.failureValue, error)
        controller.perform(.lights(false), on: .test(profile: 7), testProfile: 7) { results.append($0) }
        executor.runNext()
        controller.stop()
        await drainMainQueue()
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.last?.failureValue?.kind, .cancelled)
        executor.finishStop()
        await drainMainQueue()
    }

    @MainActor func testInvalidProfileDoesNotEnqueueOrConvertForNativeCode() async {
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let controller = HeadsetController(provider: provider, executor: executor)
        var failure: HeadsetFailure?
        controller.onRefresh = { failure = $0.failureValue }
        controller.refresh(testProfile: Int.max)
        XCTAssertEqual(failure?.kind, .invalidTestProfile(Int.max))
        controller.perform(.lights(false), on: .test(profile: Int.max), testProfile: Int.max) { failure = $0.failureValue }
        XCTAssertEqual(failure?.kind, .invalidTestProfile(Int.max))
        XCTAssertTrue(executor.jobs.isEmpty)
        XCTAssertTrue(provider.profiles.isEmpty)
    }

    @MainActor func testCancellationCallbackCanStopWithoutLeavingAnUnresolvedCommand() async {
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let controller = HeadsetController(provider: provider, executor: executor)
        controller.perform(.lights(false), on: .test(profile: 7), testProfile: 7) { _ in controller.stop() }
        var result: Result<Void, HeadsetFailure>?
        controller.perform(.lights(false), on: .test(profile: 6), testProfile: 6) { result = $0 }
        XCTAssertEqual(result?.failureValue?.kind, .cancelled)
        XCTAssertTrue(executor.jobs.isEmpty)
        executor.finishStop()
        await drainMainQueue()
    }

    @MainActor func testCancellationCallbackCanChangeModeWithoutRestoringOldRefresh() async {
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let controller = HeadsetController(provider: provider, executor: executor)
        controller.perform(.lights(false), on: .test(profile: 7), testProfile: 7) { _ in controller.refresh(testProfile: 3) }
        controller.refresh(testProfile: 6)
        executor.runNext() // Cancelled command.
        executor.runNext() // Refresh requested by the cancellation callback.
        await drainMainQueue()
        XCTAssertEqual(provider.profiles, [3])
        XCTAssertTrue(executor.jobs.isEmpty)
    }

    @MainActor private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
