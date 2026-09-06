import XCTest
@testable import HeadsetControl_MacOSTray

// Accessed only by jobs and timers on the same fixed worker thread.
private final class WorkerTransactionState: @unchecked Sendable { var active = true }

final class HeadsetIOWorkerTests: XCTestCase {
    func testPumpedRunLoopTimerCannotNestAQueuedTransaction() async {
        let worker = HeadsetIOWorker()
        let finished = expectation(description: "queued job completes after timer and transaction")
        let stopped = expectation(description: "worker cleanup completes")
        worker.enqueue {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertTrue(worker.isCurrentThread)
            // Only accessed on this worker. HIDAPI pumps this same run loop
            // during enumeration; timer callbacks must enqueue, never do I/O.
            let transaction = WorkerTransactionState()
            let timer = Timer(timeInterval: 0, repeats: false) { _ in
                worker.enqueue {
                    XCTAssertTrue(worker.isCurrentThread)
                    XCTAssertFalse(transaction.active)
                    finished.fulfill()
                }
            }
            RunLoop.current.add(timer, forMode: .default)
            CFRunLoopRunInMode(.defaultMode, 0.02, false)
            transaction.active = false
        }
        await fulfillment(of: [finished], timeout: 2)
        worker.stop(cleanup: { XCTAssertTrue(worker.isCurrentThread) }, completion: { stopped.fulfill() })
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testNativeDiscoveryDispatchesDueTimerWithoutNestingTransactions() async {
        let worker = HeadsetIOWorker.shared
        let service = HeadsetControlService()
        let timerFired = expectation(description: "HID enumeration dispatched the timer")
        let finished = expectation(description: "subsequent native transaction completes")
        worker.enqueue {
            let transaction = WorkerTransactionState()
            let timer = Timer(timeInterval: 0, repeats: false) { _ in
                timerFired.fulfill()
                worker.enqueue {
                    XCTAssertFalse(transaction.active)
                    XCTAssertEqual(service.fetchDevices(testProfile: 7).successValue?.first?.target, .test(profile: 7))
                    XCTAssertTrue(service.perform(.lights(false), on: .test(profile: 7), testProfile: 7).isSuccess)
                    finished.fulfill()
                }
            }
            RunLoop.current.add(timer, forMode: .default)
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(service.fetchDevices(testProfile: 7).successValue?.first?.target, .test(profile: 7))
            transaction.active = false
        }
        await fulfillment(of: [timerFired, finished], timeout: 2, enforceOrder: true)
    }

    @MainActor func testStopReturnsWhileNativeWorkIsBlockedAndDropsQueuedJobs() async {
        let worker = HeadsetIOWorker()
        let active = expectation(description: "native work entered")
        let stopped = expectation(description: "cleanup after active work exits")
        let release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        worker.enqueue {
            active.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            returned.signal()
        }
        await fulfillment(of: [active], timeout: 2)
        worker.enqueue { XCTFail("Queued transaction must be discarded during stop") }
        worker.stop(cleanup: {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertTrue(worker.isCurrentThread)
            XCTAssertEqual(returned.wait(timeout: .now()), .success)
        }, completion: { stopped.fulfill() })
        worker.enqueue { XCTFail("Cannot enqueue after stop") }
        // This line must execute before the active native call can return.
        release.signal()
        await fulfillment(of: [stopped], timeout: 2)
    }
}
