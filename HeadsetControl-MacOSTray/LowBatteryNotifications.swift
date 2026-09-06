import Foundation
import UserNotifications

nonisolated struct LowBatteryNotice: Equatable, Sendable {
    let target: HeadsetTarget
    let level: Int

    var identifier: String {
        switch target {
        case .physical(let usb, let attachment):
            return "lowBatteryNotification.usb.\(usb.vendor).\(usb.product).\(attachment)"
        case .test(let profile): return "lowBatteryNotification.test.\(profile)"
        }
    }
}

nonisolated enum NotificationFailure: Error, Equatable, Sendable {
    case denied
    case system(domain: String, code: Int, description: String)

    var message: String {
        switch self {
        case .denied: return NSLocalizedString("Low-battery notifications are not authorized", comment: "Notification permission failure")
        case .system: return NSLocalizedString("Low-battery notification could not be sent", comment: "Notification submission failure")
        }
    }

    init(_ error: Error) {
        let error = error as NSError
        self = .system(domain: error.domain, code: error.code, description: error.localizedDescription)
    }
}

@MainActor protocol LowBatteryNotificationDelivering: AnyObject {
    func authorize(completion: @escaping (Result<Bool, NotificationFailure>) -> Void)
    func submit(_ notice: LowBatteryNotice, completion: @escaping (Result<Void, NotificationFailure>) -> Void)
}

@MainActor final class SystemLowBatteryNotificationDelivery: LowBatteryNotificationDelivering {
    func authorize(completion: @escaping (Result<Bool, NotificationFailure>) -> Void) {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do { completion(.success(try await center.requestAuthorization(options: [.alert, .sound, .badge]))) }
                catch { completion(.failure(NotificationFailure(error))) }
            } else {
                completion(.success(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional))
            }
        }
    }

    func submit(_ notice: LowBatteryNotice, completion: @escaping (Result<Void, NotificationFailure>) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("HeadsetControl-MacOSTray", comment: "App title")
        content.body = String(format: NSLocalizedString("Low battery notification message", comment: "Low battery notification message"), notice.level)
        content.sound = UNNotificationSound.default
        let request = UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
        // Start submission in the same main-actor call that checked eligibility;
        // do not insert a Task that could begin only after stop/recovery.
        UNUserNotificationCenter.current().add(request) { error in
            let result: Result<Void, NotificationFailure> = error.map { .failure(NotificationFailure($0)) } ?? .success(())
            DispatchQueue.main.async { completion(result) }
        }
    }
}

@MainActor final class LowBatteryNotifications {
    private enum PendingAttempt: Equatable {
        case authorizing(UUID)
        case submitting(UUID)
    }

    private struct Entry {
        var submitted = false
        var pending: PendingAttempt?
    }

    private let delivery: LowBatteryNotificationDelivering
    private var entries: [HeadsetTarget: Entry] = [:]
    private var eligible: LowBatteryNotice?
    private var stopped = false
    var isStillAllowed: ((LowBatteryNotice) -> Bool)?
    var onFailure: ((HeadsetTarget, NotificationFailure) -> Void)?
    var onSuccess: ((HeadsetTarget) -> Void)?

    init(delivery: LowBatteryNotificationDelivering) { self.delivery = delivery }

    func update(devices: [HeadsetDevice], enabled: Bool, threshold: Int, testProfile: Int) {
        guard !stopped else { return }
        // Discovery can temporarily omit a headset while its receiver keeps the
        // same attachment ID. Absence cancels authorization below, but must not
        // erase a started submission or its suppression. A new attachment has
        // its own target.
        // Preserve the existing rearming rule: an explicitly available reading
        // above the threshold. Unknown/error/charging readings do not rearm.
        for device in devices {
            if let target = device.target, case .success(let battery) = device.battery,
               battery.status == .available, let level = battery.percentage, level > threshold {
                entries.removeValue(forKey: target)
            }
        }
        eligible = nil
        // Preserve first-device eligibility; this pass does not introduce
        // notifications for every connected headset or choose a new primary.
        if enabled, let device = devices.first, let target = device.target,
           target.accepts(testProfile: testProfile), case .success(let battery) = device.battery,
           battery.status == .available, let level = battery.percentage, level <= threshold {
            eligible = LowBatteryNotice(target: target, level: level)
        }
        cancelAuthorizations(except: eligible?.target)
        guard let notice = eligible else { return }
        var entry = entries[notice.target] ?? Entry()
        guard !entry.submitted, entry.pending == nil else { return }
        let attempt = UUID()
        entry.pending = .authorizing(attempt)
        entries[notice.target] = entry
        delivery.authorize { [weak self] result in
            guard let self, self.isAuthorizing(notice, attempt: attempt), let currentNotice = self.eligible else { return }
            // Keep the coalesced attempt, but use the latest eligible reading:
            // authorization may span several refreshes for the same attachment.
            switch result {
            case .failure(let error): self.finish(currentNotice, attempt: .authorizing(attempt), result: .failure(error))
            case .success(false): self.finish(currentNotice, attempt: .authorizing(attempt), result: .failure(.denied))
            case .success(true):
                // Preferences can change before their queued observer runs.
                guard self.isStillAllowed?(currentNotice) != false else { self.suspend(); return }
                self.entries[currentNotice.target]?.pending = .submitting(attempt)
                self.delivery.submit(currentNotice) { [weak self] result in
                    self?.finish(currentNotice, attempt: .submitting(attempt), result: result)
                }
            }
        }
    }

    // Discovery failure or a mode switch is not proof that a headset recovered.
    func suspend() {
        eligible = nil
        cancelAuthorizations()
    }

    func stop() {
        stopped = true
        suspend()
        entries.removeAll()
        isStillAllowed = nil
        onFailure = nil
        onSuccess = nil
    }

    private func cancelAuthorizations(except eligibleTarget: HeadsetTarget? = nil) {
        for target in Array(entries.keys) where target != eligibleTarget {
            if case .authorizing = entries[target]?.pending { entries[target]?.pending = nil }
        }
    }

    private func isAuthorizing(_ notice: LowBatteryNotice, attempt: UUID) -> Bool {
        !stopped && eligible?.target == notice.target && entries[notice.target]?.pending == .authorizing(attempt)
    }

    private func finish(_ notice: LowBatteryNotice, attempt: PendingAttempt, result: Result<Void, NotificationFailure>) {
        // Once submission starts, its outcome belongs to the attachment even if
        // it is no longer eligible. Recovery removes the entry, so its old token
        // cannot consume a newly rearmed opportunity. Stop discards all entries.
        guard !stopped, entries[notice.target]?.pending == attempt else { return }
        entries[notice.target]?.pending = nil
        switch result {
        case .success:
            entries[notice.target]?.submitted = true
            // The caller owns displayed feedback. Report the successful target
            // even after reordering so it can clear only that target's warning.
            onSuccess?(notice.target)
        case .failure(let error):
            // Keep the opportunity available for a subsequent refresh/retry.
            if eligible?.target == notice.target { onFailure?(notice.target, error) }
        }
    }
}
