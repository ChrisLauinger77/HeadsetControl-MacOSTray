import XCTest
@testable import HeadsetControl_MacOSTray

@MainActor final class RecordingNotificationDelivery: LowBatteryNotificationDelivering {
    var authorizations: [(Result<Bool, NotificationFailure>) -> Void] = []
    var submissions: [LowBatteryNotice] = []
    var completions: [(Result<Void, NotificationFailure>) -> Void] = []
    func authorize(completion: @escaping (Result<Bool, NotificationFailure>) -> Void) { authorizations.append(completion) }
    func submit(_ notice: LowBatteryNotice, completion: @escaping (Result<Void, NotificationFailure>) -> Void) {
        submissions.append(notice)
        completions.append(completion)
    }
}

@MainActor final class LowBatteryNotificationsTests: XCTestCase {
    let a = HeadsetTarget.physical(.init(vendor: 1, product: 2), attachmentID: 11)
    let b = HeadsetTarget.physical(.init(vendor: 3, product: 4), attachmentID: 22)

    func testSuppressionIsPerDeviceWhileOnlyFirstDeviceIsEligible() async {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        notifier.update(devices: [device(a, 10), device(b, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 1)
        delivery.authorizations[0](.success(true))
        delivery.completions[0](.success(()))
        notifier.update(devices: [device(b, 10), device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        delivery.authorizations[1](.success(true))
        delivery.completions[1](.success(()))
        XCTAssertEqual(delivery.submissions.map(\.target), [a, b])
        XCTAssertNotEqual(delivery.submissions[0].identifier, delivery.submissions[1].identifier)
        notifier.update(devices: [device(a, 10), device(b, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 2)
    }

    func testDenialAndSubmissionFailureDoNotConsumeOpportunity() async {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        var failures: [NotificationFailure] = []
        notifier.onFailure = { _, error in failures.append(error) }
        let update = { notifier.update(devices: [self.device(self.a, 0)], enabled: true, threshold: 25, testProfile: 0) }
        update()
        delivery.authorizations[0](.success(false))
        update()
        delivery.authorizations[1](.success(true))
        let failure = NotificationFailure.system(domain: "Test", code: 1, description: "Rejected")
        delivery.completions[0](.failure(failure))
        update()
        delivery.authorizations[2](.success(true))
        delivery.completions[1](.success(()))
        update()
        XCTAssertEqual(delivery.authorizations.count, 3)
        XCTAssertEqual(failures, [.denied, failure])
    }

    func testOnlyValidRecoveryRearmsAndFailuresNeverGeneratePercentages() async {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        func update(_ device: HeadsetDevice) { notifier.update(devices: [device], enabled: true, threshold: 25, testProfile: 0) }
        update(device(a, 10))
        delivery.authorizations[0](.success(true))
        delivery.completions[0](.success(()))
        update(device(a, 10, status: .charging))
        update(device(a, 0, status: .unavailable))
        update(device(a, -1))
        update(device(a, 101))
        var failed = device(a, 10)
        failed.battery = .failure(.init(operation: .battery, kind: .native(-4)))
        update(failed)
        update(device(a, 10))
        XCTAssertEqual(delivery.authorizations.count, 1)
        update(device(a, 26))
        update(device(a, 0))
        XCTAssertEqual(delivery.authorizations.count, 2)
    }

    func testPendingAttemptsCoalesceAndLateAuthorizationCannotSubmitAfterStop() async {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        for _ in 0..<20 { notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0) }
        XCTAssertEqual(delivery.authorizations.count, 1)
        notifier.stop()
        delivery.authorizations[0](.success(true))
        XCTAssertTrue(delivery.submissions.isEmpty)
    }

    func testPendingAuthorizationSubmitsLatestReadingWithoutRestartingAttempt() async throws {
        for (initialLevel, latestLevel) in [(10, 20), (20, 10)] {
            let delivery = RecordingNotificationDelivery()
            let notifier = LowBatteryNotifications(delivery: delivery)
            var checked: [LowBatteryNotice] = []
            notifier.isStillAllowed = { checked.append($0); return true }
            notifier.update(devices: [device(a, initialLevel)], enabled: true, threshold: 25, testProfile: 0)
            notifier.update(devices: [device(a, latestLevel)], enabled: true, threshold: 25, testProfile: 0)
            XCTAssertEqual(delivery.authorizations.count, 1)
            delivery.authorizations[0](.success(true))
            let expected = LowBatteryNotice(target: a, level: latestLevel)
            XCTAssertEqual(checked, [expected])
            XCTAssertEqual(delivery.submissions, [expected])

            // A later low reading belongs to the same attempt while submission
            // is pending; it must not discard a successful acknowledgement.
            notifier.update(devices: [device(a, 5)], enabled: true, threshold: 25, testProfile: 0)
            let completion = try XCTUnwrap(delivery.completions.first)
            completion(.success(()))
            notifier.update(devices: [device(a, 0)], enabled: true, threshold: 25, testProfile: 0)
            XCTAssertEqual(delivery.authorizations.count, 1)
        }
    }

    func testRecoveryWhileSubmissionPendingIgnoresItsLateSuccess() async {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        delivery.authorizations[0](.success(true))
        notifier.update(devices: [device(a, 50)], enabled: true, threshold: 25, testProfile: 0)
        delivery.completions[0](.success(()))
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 2)
    }

    func testUnknownIdentityAndInvalidBatteryDoNotNotify() async {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        for headset in [device(nil, 10), device(a, 10, status: .unavailable), device(a, -1), device(a, 101), device(a, 10, status: .unknown(99))] {
            notifier.update(devices: [headset], enabled: true, threshold: 25, testProfile: 0)
        }
        XCTAssertTrue(delivery.authorizations.isEmpty)
    }

    func testAuthorizationErrorsAndDisablingWhilePendingAllowRetry() async {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        delivery.authorizations[0](.failure(.system(domain: "Test", code: 1, description: "No service")))
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        notifier.update(devices: [device(a, 10)], enabled: false, threshold: 25, testProfile: 0)
        delivery.authorizations[1](.success(true))
        XCTAssertTrue(delivery.submissions.isEmpty)
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 3)
    }

    func testDiscoveryFailurePreservesSuppressionButNewAttachmentDoesNot() async {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        delivery.authorizations[0](.success(true))
        delivery.completions[0](.success(()))
        notifier.suspend()
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 1)
        let replacement = HeadsetTarget.physical(.init(vendor: 1, product: 2), attachmentID: 12)
        notifier.update(devices: [device(replacement, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 2)
        notifier.update(devices: [], enabled: true, threshold: 25, testProfile: 0)
        delivery.authorizations[1](.success(true))
        XCTAssertEqual(delivery.submissions.count, 1)
    }

    func testSuccessfulDiscoveryAbsenceDoesNotRearmTheSameAttachment() async {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        delivery.authorizations[0](.success(true))
        delivery.completions[0](.success(()))

        // The receiver can keep its attachment ID while discovery omits the headset.
        notifier.update(devices: [], enabled: true, threshold: 25, testProfile: 0)
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 1)
        XCTAssertEqual(delivery.submissions.count, 1)

        // Another device's recovery must not reset A while A is absent.
        notifier.update(devices: [device(b, 80)], enabled: true, threshold: 25, testProfile: 0)
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 1)
        notifier.update(devices: [device(a, 26)], enabled: true, threshold: 25, testProfile: 0)
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 2)
    }

    func testTestProfileNotificationCannotSuppressOrRearmPhysicalAttachment() async {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        delivery.authorizations[0](.success(true))
        delivery.completions[0](.success(()))
        notifier.suspend()
        notifier.update(devices: [device(.test(profile: 7), 10)], enabled: true, threshold: 25, testProfile: 7)
        delivery.authorizations[1](.success(true))
        delivery.completions[1](.success(()))
        notifier.suspend()
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 2)
        XCTAssertEqual(delivery.submissions.map(\.target), [a, .test(profile: 7)])
    }

    func testStartedSubmissionSurvivesTemporaryLossOfEligibility() async {
        var failed = device(a, 10)
        failed.battery = .failure(.init(operation: .battery, kind: .native(-4)))
        let transitions: [(String, [HeadsetDevice]?, Bool, Int)] = [
            ("reordered", [device(b, 80), device(a, 10)], true, 0),
            ("absent", [], true, 0),
            ("unavailable", [device(a, 0, status: .unavailable)], true, 0),
            ("charging", [device(a, 80, status: .charging)], true, 0),
            ("failed telemetry", [failed], true, 0),
            ("ambiguous", [device(nil, 10)], true, 0),
            ("disabled", [device(a, 10)], false, 0),
            ("discovery failure", nil, true, 0),
            ("test mode", [device(.test(profile: 7), 80)], true, 7)
        ]
        for (name, devices, enabled, profile) in transitions {
            for completesBeforeReturn in [true, false] {
                let delivery = RecordingNotificationDelivery()
                let notifier = LowBatteryNotifications(delivery: delivery)
                notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
                delivery.authorizations[0](.success(true))
                if let devices { notifier.update(devices: devices, enabled: enabled, threshold: 25, testProfile: profile) }
                else { notifier.suspend() }

                if completesBeforeReturn { delivery.completions[0](.success(())) }
                notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
                XCTAssertEqual(delivery.authorizations.count, 1, name)
                if !completesBeforeReturn { delivery.completions[0](.success(())) }
                notifier.update(devices: [device(a, 5)], enabled: true, threshold: 25, testProfile: 0)
                XCTAssertEqual(delivery.authorizations.count, 1, name)
                XCTAssertEqual(delivery.submissions.count, 1, name)
            }
        }
    }

    func testStartedSubmissionFailureWhileAbsentAllowsRetry() async throws {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        var failures: [NotificationFailure] = []
        notifier.onFailure = { _, error in failures.append(error) }
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        delivery.authorizations[0](.success(true))
        notifier.update(devices: [], enabled: true, threshold: 25, testProfile: 0)
        delivery.completions[0](.failure(.system(domain: "Test", code: 1, description: "Rejected")))
        XCTAssertTrue(failures.isEmpty) // No obsolete warning for an absent device.
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 2)
        let retry = try XCTUnwrap(delivery.authorizations.dropFirst().first)
        retry(.success(true))
        let completion = try XCTUnwrap(delivery.completions.dropFirst().first)
        completion(.success(()))
        notifier.update(devices: [device(a, 5)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 2)
    }

    func testOldSubmissionAfterRecoveryCannotConsumeNewAttempt() async throws {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        delivery.authorizations[0](.success(true))
        notifier.update(devices: [device(a, 50)], enabled: true, threshold: 25, testProfile: 0)
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        let authorize = try XCTUnwrap(delivery.authorizations.dropFirst().first)
        authorize(.success(true))
        delivery.completions[0](.success(())) // Belongs to the recovered episode.
        let completion = try XCTUnwrap(delivery.completions.dropFirst().first)
        completion(.failure(.system(domain: "Test", code: 1, description: "Rejected")))
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 3)
    }

    func testFeedbackReportsTheOriginatingTargetAfterReordering() async throws {
        let delivery = RecordingNotificationDelivery()
        let notifier = LowBatteryNotifications(delivery: delivery)
        var successes: [HeadsetTarget] = []
        var failures: [NotificationFailure] = []
        var failureTargets: [HeadsetTarget] = []
        notifier.onSuccess = { successes.append($0) }
        notifier.onFailure = { target, error in
            failureTargets.append(target)
            failures.append(error)
        }
        notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        delivery.authorizations[0](.success(true))
        notifier.update(devices: [device(b, 10), device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
        let authorize = try XCTUnwrap(delivery.authorizations.dropFirst().first)
        authorize(.success(false))
        delivery.completions[0](.success(()))
        XCTAssertEqual(failures, [.denied])
        XCTAssertEqual(failureTargets, [b])
        XCTAssertEqual(successes, [a])
        notifier.update(devices: [device(a, 10), device(b, 10)], enabled: true, threshold: 25, testProfile: 0)
        XCTAssertEqual(delivery.authorizations.count, 2)
    }

    func testStopIgnoresStartedSubmissionCompletions() async {
        let results: [Result<Void, NotificationFailure>] = [.success(()), .failure(.denied)]
        for result in results {
            let delivery = RecordingNotificationDelivery()
            let notifier = LowBatteryNotifications(delivery: delivery)
            var callbacks = 0
            notifier.onSuccess = { _ in callbacks += 1 }
            notifier.onFailure = { _, _ in callbacks += 1 }
            notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
            delivery.authorizations[0](.success(true))
            notifier.stop()
            delivery.completions[0](result)
            notifier.update(devices: [device(a, 10)], enabled: true, threshold: 25, testProfile: 0)
            XCTAssertEqual(callbacks, 0)
            XCTAssertEqual(delivery.authorizations.count, 1)
        }
    }

    private func device(_ target: HeadsetTarget?, _ level: Int, status: HeadsetBattery.Status = .available) -> HeadsetDevice {
        HeadsetDevice(usbID: .init(vendor: 1, product: 2), name: "Headset", vendor: "Vendor", product: "Product", capabilities: [],
                      battery: .success(.init(level: level, status: status)), target: target)
    }
}
