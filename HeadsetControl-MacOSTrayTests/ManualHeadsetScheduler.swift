import Foundation
@testable import HeadsetControl_MacOSTray

// Tests advance time and may deliberately invoke canceled callbacks, without
// sleeping or creating another HID execution path.
final class HeadsetTestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1000)
}

@MainActor final class ManualHeadsetScheduler: HeadsetScheduling {
    final class Task: HeadsetScheduledTask {
        let deadline: Date
        let action: @MainActor () -> Void
        var canceled = false
        init(deadline: Date, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }
        func cancel() { canceled = true }
    }
    let clock: HeadsetTestClock
    var tasks: [Task] = []
    var pending: [Task] { tasks.filter { !$0.canceled } }
    init(clock: HeadsetTestClock) { self.clock = clock }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> HeadsetScheduledTask {
        let task = Task(deadline: clock.now.addingTimeInterval(delay), action: action)
        tasks.append(task)
        return task
    }
    func advance(by seconds: TimeInterval) {
        clock.now.addTimeInterval(seconds)
        for task in pending where task.deadline <= clock.now {
            task.cancel()
            task.action()
        }
    }
}
