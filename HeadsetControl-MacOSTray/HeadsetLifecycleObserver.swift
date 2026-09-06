import AppKit
import IOKit

nonisolated enum HeadsetLifecycleEvent: Sendable, Equatable { case willSleep, resume, usbChanged }

@MainActor protocol HeadsetLifecycleObserving: AnyObject {
    func start(_ handler: @escaping @MainActor (HeadsetLifecycleEvent) -> Void)
    func stop()
}

@MainActor final class HeadsetLifecycleObserver: HeadsetLifecycleObserving {
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var usb: USBRegistryObservation?
    private var generation = UUID()

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) { self.center = center }

    func start(_ handler: @escaping @MainActor (HeadsetLifecycleEvent) -> Void) {
        stop()
        let generation = self.generation
        let events: [(Notification.Name, HeadsetLifecycleEvent)] = [
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.didWakeNotification, .resume),
            (NSWorkspace.screensDidWakeNotification, .resume),
            (NSWorkspace.sessionDidBecomeActiveNotification, .resume)
        ]
        for (name, event) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                // Notifications can originate on any thread. Use common modes
                // so menu tracking does not postpone the main-actor handoff.
                HeadsetMainRunLoop.perform { [weak self] in
                    guard let self, self.generation == generation else { return }
                    handler(event)
                }
            })
        }
        usb = USBRegistryObservation { [weak self] in
            guard let self, self.generation == generation else { return }
            handler(.usbChanged)
        }
        if usb == nil { NSLog("HeadsetControl: USB observation unavailable; using menu, wake and periodic refresh") }
    }

    func stop() {
        generation = UUID()
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        usb = nil // Removes the source and releases both notification iterators.
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}

// This watches IORegistry services only. It never creates an IOHIDManager,
// opens a device, or calls headsetcontrol/HIDAPI. All callbacks are delivered
// on the main run loop; the owner releases it on that same actor during stop.
private nonisolated final class USBRegistryObservation {
    private let port: IONotificationPortRef
    private let source: CFRunLoopSource
    private var arrival: io_iterator_t = 0
    private var removal: io_iterator_t = 0
    private let onChange: @MainActor () -> Void

    @MainActor init?(_ onChange: @escaping @MainActor () -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            IONotificationPortDestroy(port)
            return nil
        }
        self.port = port
        self.source = source
        self.onChange = onChange
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let observer = Unmanaged<USBRegistryObservation>.fromOpaque(context).takeUnretainedValue()
            // Draining releases every service and rearms the notification.
            if USBRegistryObservation.drain(iterator) {
                MainActor.assumeIsolated { observer.onChange() }
            }
        }
        guard let matchingArrival = IOServiceMatching("IOUSBHostDevice"),
              IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matchingArrival, callback,
                                               Unmanaged.passUnretained(self).toOpaque(), &arrival) == KERN_SUCCESS else { return nil }
        Self.drain(arrival) // Initial inventory arms observation without a spurious recovery burst.
        guard let matchingRemoval = IOServiceMatching("IOUSBHostDevice"),
              IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matchingRemoval, callback,
                                               Unmanaged.passUnretained(self).toOpaque(), &removal) == KERN_SUCCESS else { return nil }
        Self.drain(removal)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    @discardableResult private static func drain(_ iterator: io_iterator_t) -> Bool {
        var changed = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            changed = true
            IOObjectRelease(service)
        }
        return changed
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        if arrival != 0 { IOObjectRelease(arrival) }
        if removal != 0 { IOObjectRelease(removal) }
        IONotificationPortDestroy(port)
    }
}
