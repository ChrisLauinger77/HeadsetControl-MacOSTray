import Foundation

// HIDAPI schedules its manager on the calling thread's run loop. A serial
// DispatchQueue can change threads; this FIFO deliberately owns one Thread.
// Jobs are removed only by this loop, never by run-loop callbacks pumped by HID.
nonisolated final class HeadsetIOWorker: HeadsetWorkExecuting, @unchecked Sendable {
    static let shared = HeadsetIOWorker()

    private let state = State()
    private let thread: Thread

    init() {
        let state = self.state
        thread = Thread { state.run() }
        thread.name = "HeadsetControl HID"
        thread.qualityOfService = .utility
        thread.start()
    }

    var isCurrentThread: Bool { Thread.current === thread }

    func enqueue(_ work: @escaping @Sendable () -> Void) {
        state.condition.lock()
        if !state.stopping { state.jobs.append(work) }
        state.condition.signal()
        state.condition.unlock()
    }

    func stop(cleanup: @escaping @Sendable () -> Void, completion: @escaping @Sendable () -> Void) {
        state.stop(cleanup: cleanup, completion: completion)
    }

    deinit { state.stop(cleanup: {}, completion: {}) }

    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var jobs: [@Sendable () -> Void] = []
        var stopping = false
        private var finished = false
        private var cleanup: (@Sendable () -> Void)?
        private var completions: [@Sendable () -> Void] = []

        func stop(cleanup: @escaping @Sendable () -> Void, completion: @escaping @Sendable () -> Void) {
            condition.lock()
            if finished {
                condition.unlock()
                completion()
                return
            }
            if !stopping {
                stopping = true
                self.cleanup = cleanup
                jobs.removeAll()
            }
            completions.append(completion)
            condition.signal()
            condition.unlock()
        }

        func run() {
            while true {
                condition.lock()
                while jobs.isEmpty && !stopping { condition.wait() }
                if stopping {
                    let cleanup = self.cleanup
                    self.cleanup = nil
                    condition.unlock()
                    autoreleasepool { cleanup?() }
                    condition.lock()
                    finished = true
                    let completions = self.completions
                    self.completions.removeAll()
                    condition.unlock()
                    completions.forEach { $0() }
                    return
                }
                let job = jobs.removeFirst()
                condition.unlock()
                autoreleasepool { job() }
            }
        }
    }
}
