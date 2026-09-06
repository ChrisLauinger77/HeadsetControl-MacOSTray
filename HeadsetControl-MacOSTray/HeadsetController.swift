import Foundation

@MainActor final class HeadsetController {
    var onDevices: (([HeadsetDevice]) -> Void)?

    private let provider: HeadsetControlProviding
    private let executor: HeadsetWorkExecuting
    private var refreshInFlight = false
    private var pendingProfile: Int?
    private var profile = 0
    private var session = Session()
    private var stopped = false
    private var stopFinished = false
    private var stopCompletions: [() -> Void] = []

    init(provider: HeadsetControlProviding, executor: HeadsetWorkExecuting) {
        self.provider = provider
        self.executor = executor
    }

    func refresh(testProfile: Int) {
        guard !stopped else { return }
        selectProfile(testProfile)
        if refreshInFlight {
            pendingProfile = testProfile
            return
        }
        refreshInFlight = true
        let session = self.session
        let provider = self.provider
        executor.enqueue { [weak self] in
            let devices = session.isActive ? provider.fetchDevices(testProfile: testProfile) : nil
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                if self.session === session, let devices {
                    self.onDevices?(devices)
                }
                self.refreshInFlight = false
                if let pending = self.pendingProfile {
                    self.pendingProfile = nil
                    self.refresh(testProfile: pending)
                }
            }
        }
    }

    func perform(_ command: HeadsetCommand, on target: HeadsetTarget, testProfile: Int) {
        guard !stopped else { return }
        selectProfile(testProfile)
        guard target.accepts(testProfile: testProfile) else { return }
        let session = self.session
        let provider = self.provider
        executor.enqueue {
            guard session.isActive else { return }
            _ = provider.perform(command, on: target, testProfile: testProfile)
        }
    }

    // Returns immediately. The completion follows native cleanup on the worker.
    func stop(completion: @escaping () -> Void = {}) {
        if stopFinished { completion(); return }
        stopCompletions.append(completion)
        guard !stopped else { return }
        stopped = true
        session.cancel()
        pendingProfile = nil
        onDevices = nil
        let provider = self.provider
        executor.stop(cleanup: { provider.shutdown() }) { [self] in
            DispatchQueue.main.async {
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
        if refreshInFlight { pendingProfile = profile }
    }

    // The lock protects only cancellation, never a native call or callback.
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
