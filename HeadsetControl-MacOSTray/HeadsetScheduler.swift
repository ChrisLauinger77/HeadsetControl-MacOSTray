import Foundation

@MainActor protocol HeadsetScheduledTask: AnyObject {
    func cancel()
}

@MainActor protocol HeadsetScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> HeadsetScheduledTask
}

@MainActor struct MainRunLoopHeadsetScheduler: HeadsetScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> HeadsetScheduledTask {
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = min(0.1, max(0, delay) * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        return ScheduledTimer(timer)
    }

    private final class ScheduledTimer: HeadsetScheduledTask {
        let timer: Timer
        init(_ timer: Timer) { self.timer = timer }
        func cancel() { timer.invalidate() }
        deinit { timer.invalidate() }
    }
}

// Main-queue blocks need not run inside a nested AppKit tracking loop. Explicit
// common-mode delivery keeps results and cancellation callbacks responsive there.
nonisolated enum HeadsetMainRunLoop {
    static func perform(_ action: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { action() }
        }
    }
}
