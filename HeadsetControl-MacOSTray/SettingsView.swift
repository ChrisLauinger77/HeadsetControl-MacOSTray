import SwiftUI
import AppKit

// SwiftUI wrapper for NSImage
struct AppIconImage: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = NSApplication.shared.applicationIconImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        return imageView
    }
    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

struct SettingsView: View {
    @AppStorage("sidetoneOff") var sidetoneOff: Int = 0
    @AppStorage("sidetoneLow") var sidetoneLow: Int = 32
    @AppStorage("sidetoneMid") var sidetoneMid: Int = 64
    @AppStorage("sidetoneHigh") var sidetoneHigh: Int = 96
    @AppStorage("sidetoneMax") var sidetoneMax: Int = 128
    var onClose: (() -> Void)? = nil
    @AppStorage("updateInterval") var updateInterval: Double = 600
    @AppStorage("headsetcontrolPath") var headsetcontrolPath: String = "/opt/homebrew/bin/headsetcontrol"
    @AppStorage("testMode") var testMode: Int = 0
    @AppStorage("equalizerPresets") var equalizerPresets: String = "Preset 1,Preset 2,Preset 3,Preset 4"
    @AppStorage("notifyOnLowBattery") var notifyOnLowBattery: Bool = true
    @AppStorage("inactiveTimeOptions") private var inactiveTimeOptionsRaw: String = "1,2,5,10,15,30,45,60,75,90"

    private let inactiveTimeOptions: [Int] = [1, 2, 5, 10, 15, 30, 45, 60, 75, 90]

    private var normalizedInactiveTimeOptions: [Int] {
        parseInactiveTimeOptions(raw: inactiveTimeOptionsRaw)
    }

    private var selectedInactiveTimeMinutes: Set<Int> {
        Set(normalizedInactiveTimeOptions)
    }

    private func parseInactiveTimeOptions(raw: String) -> [Int] {
        let allowed = Set(inactiveTimeOptions)
        let parsed = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let filtered = parsed.filter { allowed.contains($0) }
        return Array(Set(filtered)).sorted()
    }

    private func toggleInactiveTime(_ minutes: Int) {
        var selected = Set(normalizedInactiveTimeOptions)
        if selected.contains(minutes) {
            selected.remove(minutes)
        } else {
            selected.insert(minutes)
        }
        inactiveTimeOptionsRaw = selected.sorted().map(String.init).joined(separator: ",")
    }

    private func inactiveTimeLabel(for minutes: Int) -> String {
        switch minutes {
        case 1:
            return NSLocalizedString("1 Minute", comment: "Inactive Time 1 minute option")
        case 2:
            return NSLocalizedString("2 Minutes", comment: "Inactive Time 2 minutes option")
        case 5:
            return NSLocalizedString("5 Minutes", comment: "Inactive Time 5 minutes option")
        case 10:
            return NSLocalizedString("10 Minutes", comment: "Inactive Time 10 minutes option")
        case 15:
            return NSLocalizedString("15 Minutes", comment: "Inactive Time 15 minutes option")
        case 30:
            return NSLocalizedString("30 Minutes", comment: "Inactive Time 30 minutes option")
        case 45:
            return NSLocalizedString("45 Minutes", comment: "Inactive Time 45 minutes option")
        case 60:
            return NSLocalizedString("60 Minutes", comment: "Inactive Time 60 minutes option")
        case 75:
            return NSLocalizedString("75 Minutes", comment: "Inactive Time 75 minutes option")
        case 90:
            return NSLocalizedString("90 Minutes", comment: "Inactive Time 90 minutes option")
        default:
            return "\(minutes)"
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    private var generalSettingsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("General Settings", comment: "General settings section header"))
                .font(.headline)
            HStack(alignment: .center) {
                Text(NSLocalizedString("Test Mode:", comment: "Test mode label"))
                Picker("", selection: $testMode) {
                    Text(NSLocalizedString("Device 1", comment: "Test mode device 1"))
                        .tag(1)
                    Text(NSLocalizedString("Device 2", comment: "Test mode device 2"))
                        .tag(2)
                    Text(NSLocalizedString("Device 3", comment: "Test mode device 3"))
                        .tag(3)
                    Text(NSLocalizedString("Device 4", comment: "Test mode device 4"))
                        .tag(4)
                    Text(NSLocalizedString("Device 5", comment: "Test mode device 5"))
                        .tag(5)
                    Text(NSLocalizedString("Device 6", comment: "Test mode device 6"))
                        .tag(6)
                    Text(NSLocalizedString("Device 7", comment: "Test mode device 7"))
                        .tag(7)
                    Text(NSLocalizedString("Disabled", comment: "Test mode disabled"))
                        .tag(0)
                }
                .pickerStyle(.menu)
            }
            HStack(alignment: .center) {
                Text(NSLocalizedString("Update Interval (seconds):", comment: "Update interval label"))
                Slider(value: $updateInterval, in: 60...3600, step: 30)
                Text("\(Int(updateInterval)) s")
            }
            HStack(alignment: .center) {
                Text(NSLocalizedString("Binary Path:", comment: "Binary path label"))
                TextField(NSLocalizedString("Binary Path:", comment: "Binary path label"), text: $headsetcontrolPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(false)
            }
            Toggle(NSLocalizedString("Notification on low battery", comment: "Low battery notification toggle label"), isOn: $notifyOnLowBattery)
        }
        .padding()
    }

    private var sidetoneSettingsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Sidetone", comment: "Sidetone section header"))
                .font(.headline)
            Text(NSLocalizedString("Sidetone Level Values (set -1 to hide)", comment: "Sidetone level info")).font(.subheadline)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(NSLocalizedString("Off:", comment: "Sidetone off label"))
                    TextField(NSLocalizedString("Off", comment: "Sidetone off field"), value: $sidetoneOff, formatter: NumberFormatter())
                }
                HStack {
                    Text(NSLocalizedString("Low:", comment: "Sidetone low label"))
                    TextField(NSLocalizedString("Low", comment: "Sidetone low field"), value: $sidetoneLow, formatter: NumberFormatter())
                }
                HStack {
                    Text(NSLocalizedString("Medium:", comment: "Sidetone medium label"))
                    TextField(NSLocalizedString("Medium", comment: "Sidetone medium field"), value: $sidetoneMid, formatter: NumberFormatter())
                }
                HStack {
                    Text(NSLocalizedString("High:", comment: "Sidetone high label"))
                    TextField(NSLocalizedString("High", comment: "Sidetone high field"), value: $sidetoneHigh, formatter: NumberFormatter())
                }
                HStack {
                    Text(NSLocalizedString("Maximum:", comment: "Sidetone maximum label"))
                    TextField(NSLocalizedString("Maximum", comment: "Sidetone maximum field"), value: $sidetoneMax, formatter: NumberFormatter())
                }
            }
        }
        .padding()
    }

    private var inactiveTimeSettingsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Inactive Time", comment: "Inactive time options section header"))
                .font(.headline)
            Text(NSLocalizedString("(Off is always included.)", comment: "Inactive time options help text"))
                .font(.subheadline)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(NSLocalizedString("Off", comment: "Inactive Time off option"))
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundColor(.secondary)
                }
                ForEach(inactiveTimeOptions, id: \.self) { minutes in
                    Button(action: { toggleInactiveTime(minutes) }) {
                        HStack {
                            Text(inactiveTimeLabel(for: minutes))
                            Spacer()
                            Image(systemName: "checkmark")
                                .opacity(selectedInactiveTimeMinutes.contains(minutes) ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
    }

    private var equalizerSettingsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Equalizer Presets", comment: "Equalizer presets section header"))
                .font(.headline)
            Text(NSLocalizedString("Comma-separated list of preset names.", comment: "Equalizer presets help text"))
                .font(.subheadline)
                .foregroundColor(.secondary)
            TextField(NSLocalizedString("Preset names", comment: "Equalizer presets text field label"), text: $equalizerPresets)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
    }

    private var aboutTab: some View {
        VStack(alignment: .center, spacing: 16) {
            AppIconImage()
                .frame(width: 72, height: 72)
                .shadow(radius: 4)
            Text(NSLocalizedString("HeadsetControl-MacOSTray", comment: "App title"))
                .font(.title2)
                .bold()
            VStack(spacing: 6) {
                Text("\(NSLocalizedString("Version", comment: "App version label")): \(appVersion)")
                Text("\(NSLocalizedString("Build", comment: "App build label")): \(appBuild)")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            
            Link(NSLocalizedString("GitHub Repository", comment: "GitHub link label"),
                 destination: URL(string: "https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray")!)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TabView {
                generalSettingsTab
                    .tabItem { Text(NSLocalizedString("General", comment: "General settings tab")) }
                sidetoneSettingsTab
                    .tabItem { Text(NSLocalizedString("Sidetone", comment: "Sidetone tab")) }
                inactiveTimeSettingsTab
                    .tabItem { Text(NSLocalizedString("Inactive Time", comment: "Inactive time options tab")) }
                equalizerSettingsTab
                    .tabItem { Text(NSLocalizedString("Equalizer Presets", comment: "Equalizer presets tab")) }
                aboutTab
                    .tabItem { Text(NSLocalizedString("About", comment: "About tab")) }
            }

            Divider()

            HStack(spacing: 8) {
                Spacer()
                Button(NSLocalizedString("Refresh", comment: "Refresh button")) {
                    NotificationCenter.default.post(name: .refreshHeadsetStatus, object: nil)
                }
                Button(NSLocalizedString("Close", comment: "Close button")) {
                    onClose?()
                }
                Spacer()
            }
        }
        .padding()
    }
}

extension Notification.Name {
    static let refreshHeadsetStatus = Notification.Name("refreshHeadsetStatus")
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
