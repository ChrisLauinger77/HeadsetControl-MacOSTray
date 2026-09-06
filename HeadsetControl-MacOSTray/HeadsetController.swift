import Foundation

@MainActor final class HeadsetController {
    var onRefresh: ((Result<[HeadsetDevice], HeadsetFailure>) -> Void)?
    var onSnapshotInvalidated: (() -> Void)?
    private(set) var snapshot = HeadsetSnapshot()
    var snapshotState: HeadsetSnapshot.State { snapshot.state(at: now(), maximumAge: snapshotMaximumAge) }
    private var snapshotMaximumAge: TimeInterval

    private let scheduler: HeadsetScheduling
    private let now: @Sendable () -> Date
    private var observationGeneration = 0
    private var expirationTask: HeadsetScheduledTask?
    private var expirationToken = UUID()
    private var recoveryTask: HeadsetScheduledTask?
    private var recoveryToken = UUID()
    private var recoveryIsDebouncing = false
    private var recoveryRetry: Int?
    private static let retryDelays: [TimeInterval] = [2, 5, 10]

    private let provider: HeadsetControlProviding
    private let executor: HeadsetWorkExecuting
    private var refreshInFlight = false
    private var pendingProfile: Int?
    private var profile = 0
    private var session = Session()
    private var stopped = false
    private var stopFinished = false
    private var stopCompletions: [() -> Void] = []
    private var commands: [UUID: (Result<Void, HeadsetFailure>) -> Void] = [:]

    init(provider: HeadsetControlProviding, executor: HeadsetWorkExecuting,
         scheduler: HeadsetScheduling? = nil, now: @escaping @Sendable () -> Date = { Date() },
         refreshInterval: Int = AppDefaults.updateInterval) {
        self.provider = provider
        self.executor = executor
        self.scheduler = scheduler ?? MainRunLoopHeadsetScheduler()
        self.now = now
        snapshotMaximumAge = AppDefaults.snapshotMaximumAge(for: refreshInterval)
    }

    func updateRefreshInterval(_ interval: Int) {
        guard !stopped else { return }
        let maximumAge = AppDefaults.snapshotMaximumAge(for: interval)
        guard maximumAge != snapshotMaximumAge else { return }
        let previousState = snapshotState
        snapshotMaximumAge = maximumAge
        scheduleExpiration()
        // Age expiration is computed, never latched into explicit invalidation.
        // Extending the interval can therefore make an otherwise valid cache fresh.
        if snapshotState == .stale, previousState != .stale { onSnapshotInvalidated?() }
    }

    // Menu opening shares existing work; it must not create a perpetual
    // followup as AppKit repeatedly asks for menu updates during tracking.
    func refreshIfNeeded(testProfile: Int) {
        guard !stopped else { return }
        if profile == testProfile {
            guard snapshotState != .fresh && snapshotState != .empty else { return }
            guard !refreshInFlight, recoveryTask == nil else { return }
        }
        refresh(testProfile: testProfile)
    }

    func invalidateSnapshot() {
        guard !stopped else { return }
        observationGeneration += 1
        // Coalesced requests also belong to the pre-event observation. Do not
        // let completion of old work relaunch them under the new generation.
        pendingProfile = nil
        snapshot.invalidate()
        expirationTask?.cancel()
        expirationTask = nil
        endRecovery()
        onSnapshotInvalidated?()
    }

    // A new external event starts a bounded recovery burst. Events within the
    // debounce share its first deadline, so a busy USB bus cannot postpone it.
    func recover(testProfile: Int) {
        guard !stopped else { return }
        selectProfile(testProfile)
        guard !stopped, profile == testProfile else { return }
        observationGeneration += 1
        snapshot.invalidate()
        expirationTask?.cancel()
        expirationTask = nil
        recoveryRetry = 0
        if !recoveryIsDebouncing {
            scheduleRecovery(after: 0.75, testProfile: testProfile, debouncing: true)
        }
        onSnapshotInvalidated?()
    }

    private func cancelRecoveryTask() {
        recoveryToken = UUID()
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryIsDebouncing = false
    }

    private func endRecovery() {
        cancelRecoveryTask()
        recoveryRetry = nil
    }

    private func scheduleRecovery(after delay: TimeInterval, testProfile: Int, debouncing: Bool = false) {
        cancelRecoveryTask()
        recoveryIsDebouncing = debouncing
        let token = recoveryToken
        recoveryTask = scheduler.schedule(after: delay) { [weak self] in
            guard let self, !self.stopped, self.recoveryToken == token, self.profile == testProfile else { return }
            self.cancelRecoveryTask()
            self.refresh(testProfile: testProfile)
        }
    }

    private func continueRecovery(after result: Result<[HeadsetDevice], HeadsetFailure>) {
        guard let retry = recoveryRetry else { return }
        if snapshotState == .fresh, case .success(let devices) = result, !devices.isEmpty,
           devices.allSatisfy({ device in
               guard device.failures.isEmpty else { return false }
               if case .success(let battery) = device.battery { return battery.status == .available || battery.status == .charging }
               return true
           }) {
            endRecovery()
        } else if retry < Self.retryDelays.count {
            recoveryRetry = retry + 1
            scheduleRecovery(after: Self.retryDelays[retry], testProfile: profile)
        } else {
            endRecovery() // Periodic polling and a later stale menu can still recover.
        }
    }

    private func scheduleExpiration() {
        expirationTask?.cancel()
        expirationTask = nil
        expirationToken = UUID()
        guard let observedAt = snapshot.observedAt,
              snapshotState == .fresh || snapshotState == .empty else { return }
        let generation = observationGeneration
        let token = expirationToken
        expirationTask = scheduler.schedule(after: max(0, snapshotMaximumAge - now().timeIntervalSince(observedAt))) { [weak self] in
            guard let self, !self.stopped, self.observationGeneration == generation,
                  self.expirationToken == token, self.snapshot.observedAt == observedAt,
                  self.snapshotState != .fresh && self.snapshotState != .empty else { return }
            self.expirationTask = nil
            self.onSnapshotInvalidated?()
        }
    }

    func refresh(testProfile: Int) {
        guard !stopped else { return }
        selectProfile(testProfile)
        // Cancelling old commands invokes caller code, which may stop or select
        // another mode before this request resumes.
        guard !stopped, profile == testProfile else { return }
        guard AppDefaults.testProfileRange.contains(testProfile) else {
            pendingProfile = nil
            onRefresh?(.failure(.init(operation: .discovery, kind: .invalidTestProfile(testProfile))))
            return
        }
        if refreshInFlight {
            pendingProfile = testProfile
            return
        }
        cancelRecoveryTask() // This request also satisfies any scheduled retry.
        refreshInFlight = true
        let session = self.session
        let generation = observationGeneration
        let provider = self.provider
        let now = self.now
        executor.enqueue { [weak self] in
            // Use the beginning of native observation, not delayed UI delivery,
            // as a conservative freshness timestamp for the whole transaction.
            let observedAt = now()
            let result = session.isActive ? provider.fetchDevices(testProfile: testProfile) : nil
            HeadsetMainRunLoop.perform { [weak self] in
                guard let self, !self.stopped else { return }
                if self.session === session, self.observationGeneration == generation, let result {
                    self.snapshot.observe(result, at: observedAt)
                    self.scheduleExpiration()
                    self.continueRecovery(after: result)
                    self.onRefresh?(result)
                }
                self.refreshInFlight = false
                if let pending = self.pendingProfile {
                    self.pendingProfile = nil
                    self.refresh(testProfile: pending)
                }
            }
        }
    }

    func perform(_ command: HeadsetCommand, on target: HeadsetTarget, testProfile: Int,
                 completion: @escaping (Result<Void, HeadsetFailure>) -> Void = { _ in }) {
        guard !stopped else { completion(.failure(.init(operation: .command, kind: .stopped))); return }
        selectProfile(testProfile)
        guard !stopped, profile == testProfile else {
            completion(.failure(.init(operation: .command, kind: .cancelled)))
            return
        }
        guard AppDefaults.testProfileRange.contains(testProfile) else {
            completion(.failure(.init(operation: .command, kind: .invalidTestProfile(testProfile))))
            return
        }
        guard target.accepts(testProfile: testProfile) else {
            completion(.failure(.init(operation: .command, kind: .targetUnavailable)))
            return
        }
        let id = UUID()
        commands[id] = completion
        let session = self.session
        let provider = self.provider
        executor.enqueue { [weak self] in
            guard session.isActive else { return }
            let result = provider.perform(command, on: target, testProfile: testProfile)
            HeadsetMainRunLoop.perform { [weak self] in
                guard let self, !self.stopped, self.session === session,
                      let completion = self.commands.removeValue(forKey: id) else { return }
                completion(result)
            }
        }
    }

    // Cancellation resolves queued callers once, even when the executor drops
    // their jobs. Late worker completions cannot publish UI or resolve twice.
    private func cancelCommands() {
        let callbacks = Array(commands.values)
        commands.removeAll()
        callbacks.forEach { $0(.failure(.init(operation: .command, kind: .cancelled))) }
    }

    func stop(completion: @escaping () -> Void = {}) {
        if stopFinished { completion(); return }
        stopCompletions.append(completion)
        guard !stopped else { return }
        stopped = true
        session.cancel()
        pendingProfile = nil
        onRefresh = nil
        onSnapshotInvalidated = nil
        expirationTask?.cancel()
        expirationTask = nil
        endRecovery()
        snapshot = HeadsetSnapshot()
        cancelCommands()
        let provider = self.provider
        executor.stop(cleanup: { provider.shutdown() }) { [self] in
            HeadsetMainRunLoop.perform {
                self.stopFinished = true
                let completions = self.stopCompletions
                self.stopCompletions.removeAll()
                completions.forEach { $0() }
            }
        }
    }

    private func selectProfile(_ profile: Int) {
        guard profile != self.profile else { return }
        session.cancel()
        session = Session()
        self.profile = profile
        observationGeneration += 1
        snapshot = HeadsetSnapshot()
        expirationTask?.cancel()
        expirationTask = nil
        endRecovery()
        if refreshInFlight { pendingProfile = profile }
        cancelCommands()
    }

    private nonisolated final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true

        nonisolated var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return active
        }

        nonisolated func cancel() {
            lock.lock()
            active = false
            lock.unlock()
        }
    }
}
