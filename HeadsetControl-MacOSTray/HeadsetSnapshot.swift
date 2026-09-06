import Foundation

nonisolated struct HeadsetSnapshot {
    enum State: Equatable { case unobserved, fresh, empty, stale, failed }

    private(set) var devices: [HeadsetDevice]?
    private(set) var observedAt: Date?
    private(set) var failure: HeadsetFailure?
    private var invalidated = false

    func state(at now: Date, maximumAge: TimeInterval) -> State {
        if failure != nil { return .failed }
        guard let observedAt, let devices else { return .unobserved }
        let age = now.timeIntervalSince(observedAt)
        guard !invalidated, maximumAge.isFinite, age >= 0, age < maximumAge else { return .stale }
        return devices.isEmpty ? .empty : .fresh
    }

    mutating func invalidate() { invalidated = true }

    mutating func observe(_ result: Result<[HeadsetDevice], HeadsetFailure>, at date: Date) {
        switch result {
        case .success(let devices):
            self.devices = devices
            observedAt = date
            failure = nil
            invalidated = false
        case .failure(let failure):
            self.failure = failure // Retain the last successful observation as cached data.
        }
    }
}
