import Foundation

@MainActor final class HeadsetController {
    var onRefresh: ((Result<[HeadsetDevice], HeadsetFailure>) -> Void)?

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

    init(provider: HeadsetControlProviding, executor: HeadsetWorkExecuting) {
        self.provider = provider
        self.executor = executor
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
        refreshInFlight = true
        let session = self.session
        let provider = self.provider
        executor.enqueue { [weak self] in
            let result = session.isActive ? provider.fetchDevices(testProfile: testProfile) : nil
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                if self.session === session, let result { self.onRefresh?(result) }
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
            DispatchQueue.main.async {
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
        cancelCommands()
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
