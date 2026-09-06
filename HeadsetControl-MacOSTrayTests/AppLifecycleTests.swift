import AppKit
import XCTest
@testable import HeadsetControl_MacOSTray

@MainActor final class RecordingLifecycleObserver: HeadsetLifecycleObserving {
    var handler: (@MainActor (HeadsetLifecycleEvent) -> Void)?
    var starts = 0
    var stops = 0
    func start(_ handler: @escaping @MainActor (HeadsetLifecycleEvent) -> Void) { starts += 1; self.handler = handler }
    func stop() { stops += 1; handler = nil }
}

@MainActor final class AppLifecycleTests: XCTestCase {
    @MainActor private final class Fixture {
        let clock = HeadsetTestClock()
        let executor = ManualHeadsetExecutor()
        let provider = RecordingHeadsetProvider()
        let observer = RecordingLifecycleObserver()
        let delivery = RecordingNotificationDelivery()
        let scheduler: ManualHeadsetScheduler
        let controller: HeadsetController
        let delegate: AppDelegate
        init() {
            AppDefaults.standard.set(7, forKey: "testMode")
            AppDefaults.standard.set(false, forKey: "notifyOnLowBattery")
            scheduler = ManualHeadsetScheduler(clock: clock)
            let clock = self.clock
            controller = HeadsetController(provider: provider, executor: executor, scheduler: scheduler, now: { clock.now })
            delegate = AppDelegate(headsetController: controller, notificationDelivery: delivery, lifecycleObserver: observer)
            provider.devices = [HeadsetDevice(usbID: .testDevice, name: "Fake", vendor: "Vendor", product: "Product", capabilities: [],
                                              battery: .success(.init(level: 80, status: .available)), target: .test(profile: 7))]
        }
        func finishRefresh() async {
            XCTAssertEqual(executor.jobs.count, 1)
            guard !executor.jobs.isEmpty else { return }
            executor.runNext()
            await withCheckedContinuation { continuation in HeadsetMainRunLoop.perform { continuation.resume() } }
        }
        func stop() { delegate.stop(); executor.finishStop() }
    }

    override func tearDown() {
        AppDefaults.standard.removeObject(forKey: "testMode")
        AppDefaults.standard.removeObject(forKey: "notifyOnLowBattery")
        super.tearDown()
    }

    func testMenuOpeningRefreshesStaleCacheAndUpdatesOpenMenuAsynchronously() async {
        let f = Fixture()
        f.delegate.updateStatusItem()
        await f.finishRefresh()
        f.scheduler.advance(by: 60)
        let menu = NSMenu()
        f.delegate.menuNeedsUpdate(menu)
        f.delegate.menuWillOpen(menu)
        XCTAssertEqual(f.provider.profiles.count, 1) // Opening did not call native code.
        XCTAssertTrue(menu.items.contains { $0.title == NSLocalizedString("Device data may be out of date", comment: "") })
        XCTAssertTrue(menu.items.contains { $0.title.contains("80%") })
        for _ in 0..<5 { f.delegate.menuNeedsUpdate(menu) }
        f.provider.devices[0].battery = .success(.init(level: 90, status: .available))
        await f.finishRefresh()
        XCTAssertTrue(menu.items.contains { $0.title.contains("90%") })
        XCTAssertFalse(menu.items.contains { $0.title == NSLocalizedString("Device data may be out of date", comment: "") })
        XCTAssertTrue(f.executor.jobs.isEmpty)
        f.delegate.menuDidClose(menu)
        f.stop()
    }

    func testFailedDiscoveryLabelsAndPreservesCacheUntilSuccessfulEmptyResult() async {
        let f = Fixture()
        f.delegate.updateStatusItem()
        await f.finishRefresh()
        f.provider.fetchFailure = .init(operation: .discovery, kind: .native(-5))
        f.delegate.updateStatusItem()
        await f.finishRefresh()
        let menu = NSMenu()
        f.delegate.rebuildMenu(menu)
        XCTAssertEqual(f.delegate.latestDevices?.count, 1)
        XCTAssertTrue(menu.items.contains { $0.title.contains("80%") })
        XCTAssertTrue(menu.items.contains { $0.title == NSLocalizedString("Device data may be out of date", comment: "") })
        XCTAssertFalse(menu.items.contains { $0.title == NSLocalizedString("No devices found", comment: "") })
        f.provider.fetchFailure = nil
        f.provider.devices = []
        f.delegate.updateStatusItem()
        await f.finishRefresh()
        f.delegate.rebuildMenu(menu)
        XCTAssertEqual(f.delegate.latestDevices?.count, 0)
        XCTAssertTrue(menu.items.contains { $0.title == NSLocalizedString("No devices found", comment: "") })
        XCTAssertFalse(menu.items.contains { $0.title.contains("80%") })
        f.stop()
    }

    func testStopDetachesObserversTimersMenuAndRejectsAllLateEntryPoints() async throws {
        let f = Fixture()
        f.delegate.startLifecycleObservation()
        f.delegate.startStatusUpdateTimer()
        let periodic = try XCTUnwrap(f.delegate.statusUpdateTimer)
        let callback = try XCTUnwrap(f.observer.handler)
        callback(.resume)
        let recovery = try XCTUnwrap(f.scheduler.pending.first)
        f.scheduler.advance(by: 0.75)
        f.executor.runNext() // A result remains queued on the main actor.
        let menu = NSMenu()
        menu.delegate = f.delegate
        f.delegate.statusMenu = menu
        f.delegate.menuWillOpen(menu)
        var finished = false
        f.delegate.stop { finished = true }
        XCTAssertFalse(finished)
        XCTAssertEqual(f.observer.stops, 1)
        XCTAssertNil(menu.delegate)
        XCTAssertNil(f.delegate.statusMenu)
        XCTAssertFalse(periodic.isValid)
        callback(.resume)
        callback(.usbChanged)
        recovery.action()
        periodic.fire()
        f.delegate.menuNeedsUpdate(menu)
        f.delegate.startLifecycleObservation()
        let command = NSMenuItem()
        command.representedObject = HeadsetMenuAction(target: .test(profile: 7), value: 0)
        f.delegate.setLights(command)
        await withCheckedContinuation { continuation in HeadsetMainRunLoop.perform { continuation.resume() } }
        XCTAssertEqual(f.observer.starts, 1)
        XCTAssertNil(f.delegate.latestDevices)
        XCTAssertTrue(f.executor.jobs.isEmpty)
        XCTAssertTrue(f.provider.commands.isEmpty)
        XCTAssertTrue(menu.items.isEmpty)
        f.executor.finishStop()
        await withCheckedContinuation { continuation in HeadsetMainRunLoop.perform { continuation.resume() } }
        XCTAssertTrue(finished)
    }

    func testUSBEventsAreIgnoredInTestModeAndResumeEventsCoalesce() async throws {
        let f = Fixture()
        f.delegate.startLifecycleObservation()
        let callback = try XCTUnwrap(f.observer.handler)
        callback(.usbChanged)
        XCTAssertTrue(f.scheduler.pending.isEmpty)
        callback(.willSleep)
        for _ in 0..<10 { callback(.resume) }
        XCTAssertEqual(f.scheduler.pending.count, 1)
        f.scheduler.advance(by: 0.75)
        XCTAssertEqual(f.executor.jobs.count, 1)
        f.stop()
    }

    func testPeriodicAndRecoveryTimersFireDuringMenuTracking() async throws {
        let f = Fixture()
        _ = NSApplication.shared
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
        f.delegate.startStatusUpdateTimer()
        let timer = try XCTUnwrap(f.delegate.statusUpdateTimer)
        XCTAssertGreaterThan(timer.tolerance, 0)
        timer.fireDate = Date(timeIntervalSinceNow: -1)
        var fired = false
        let recovery = MainRunLoopHeadsetScheduler().schedule(after: 0) { fired = true }
        runLoop(.eventTracking)
        XCTAssertTrue(fired)
        XCTAssertEqual(f.executor.jobs.count, 1)
        recovery.cancel()
        f.stop()
    }

    func testRefreshResultCanPublishDuringMenuTracking() async {
        let f = Fixture()
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
        f.delegate.updateStatusItem()
        f.executor.runNext()
        runLoop(.eventTracking)
        XCTAssertEqual(f.delegate.latestDevices?.count, 1)
        f.stop()
    }

    // Deliberately model AppKit's nested tracking loop in a synchronous seam.
    private func runLoop(_ mode: RunLoop.Mode) {
        CFRunLoopRunInMode(CFRunLoopMode(rawValue: mode.rawValue as CFString), 0.02, false)
    }

    func testWorkspaceObserverUsesCorrectCenterAndRejectsQueuedEventsAfterStop() async {
        let center = NotificationCenter()
        let observer = HeadsetLifecycleObserver(center: center)
        var events: [HeadsetLifecycleEvent] = []
        observer.start { events.append($0) }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        runLoop(.default)
        XCTAssertEqual(events, [.resume, .resume])
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        observer.stop()
        runLoop(.default)
        XCTAssertEqual(events, [.resume, .resume])
        observer.start { events.append($0) }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        runLoop(.default)
        XCTAssertEqual(events, [.resume, .resume, .willSleep])
        observer.stop()
    }
}
