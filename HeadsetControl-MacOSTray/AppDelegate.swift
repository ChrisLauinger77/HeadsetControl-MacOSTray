import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var updateInterval: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "updateInterval")
            return value == 0 ? 600 : value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "updateInterval")
        }
    }

    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?
    var settingsWindow: NSWindow?

    var statusUpdateTimer: Timer?
    var latestDevices: [[String: Any]]? = nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let sfImage = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Headset") {
                button.image = sfImage
                button.image?.isTemplate = true
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        statusMenu = menu

        // Observe refresh notification
        NotificationCenter.default.addObserver(self, selector: #selector(handleRefreshNotification), name: .refreshHeadsetStatus, object: nil)

        // Start timer for periodic updates
        startStatusUpdateTimer()
        // Initial update
        updateStatusItem()
    }

    func startStatusUpdateTimer() {
        statusUpdateTimer?.invalidate()
        let interval = Double(updateInterval)
        statusUpdateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateStatusItem()
        }
    }

    @objc func handleRefreshNotification() {
        updateStatusItem()
    }

    func updateStatusItem() {
        let path = UserDefaults.standard.string(forKey: "headsetcontrolPath") ?? "/opt/homebrew/bin/headsetcontrol"
        let testMode = UserDefaults.standard.bool(forKey: "testMode")
        var arguments = ["-o", "json"]
        if testMode {
            arguments.append("--test-device")
        }
        var batteryLevelText: String? = nil
        var devicesResult: [[String: Any]]? = nil
        let task = Process()
        task.launchPath = path
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let devices = json["devices"] as? [[String: Any]], !devices.isEmpty {
                    devicesResult = devices
                    if let battery = devices[0]["battery"] as? [String: Any], let level = battery["level"] as? Int {
                        batteryLevelText = "\(level)%"
                    }
                }
            }
        } catch {
            // Ignore errors for tray icon, but could show error icon/text if desired
        }
        // Update tray icon title with battery level
        DispatchQueue.main.async {
            if let button = self.statusItem?.button {
                if let batteryText = batteryLevelText {
                    button.title = " " + batteryText
                } else {
                    button.title = ""
                }
            }
            self.latestDevices = devicesResult
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let devices = latestDevices, !devices.isEmpty else {
            menu.addItem(withTitle: "No devices found", action: nil, keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Open Settings", action: #selector(openSettings), keyEquivalent: "s")
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            return
        }
        for (idx, device) in devices.enumerated() {
            let deviceName = device["device"] as? String ?? "Unknown Device"
            let vendor = device["vendor"] as? String ?? "Unknown Vendor"
            let product = device["product"] as? String ?? "Unknown Product"
            menu.addItem(withTitle: "Device: \(deviceName)", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Vendor: \(vendor)", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Product: \(product)", action: nil, keyEquivalent: "")
            if let battery = device["battery"] as? [String: Any], let level = battery["level"] as? Int {
                menu.addItem(withTitle: "Battery: \(level)%", action: nil, keyEquivalent: "")
            }
            if let chatmix = device["chatmix"] {
                menu.addItem(withTitle: "Chatmix: \(chatmix)", action: nil, keyEquivalent: "")
            }
            if idx < devices.count - 1 {
                menu.addItem(NSMenuItem.separator())
            }
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Open Settings", action: #selector(openSettings), keyEquivalent: "s")
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func openSettings() {
        guard let mainWindow = NSApplication.shared.windows.first else { return }
        if settingsWindow == nil {
            // Pass a close handler to SettingsView that ends the sheet
            let settingsView = SettingsView(onClose: { [weak self] in
                if let window = self?.settingsWindow {
                    mainWindow.endSheet(window)
                    self?.settingsWindow = nil
                }
            })
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "HeadsetControl-MacOSTray"
            window.setContentSize(NSSize(width: 500, height: 400))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
            mainWindow.beginSheet(window, completionHandler: { _ in
                self.settingsWindow = nil
            })
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
