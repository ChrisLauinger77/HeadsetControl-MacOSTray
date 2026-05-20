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

struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }
}

struct SettingsView: View {
    @AppStorage("sidetoneOff") var sidetoneOff: Int = 0
    @AppStorage("sidetoneLow") var sidetoneLow: Int = 32
    @AppStorage("sidetoneMid") var sidetoneMid: Int = 64
    @AppStorage("sidetoneHigh") var sidetoneHigh: Int = 96
    @AppStorage("sidetoneMax") var sidetoneMax: Int = 128
    var onClose: (() -> Void)? = nil
    @AppStorage("updateInterval") var updateInterval: Double = 600
    @AppStorage("testMode") var testMode: Int = 0
    @AppStorage("equalizerPresets") var equalizerPresets: String = "Preset 1,Preset 2,Preset 3,Preset 4"
    @AppStorage("notifyOnLowBattery") var notifyOnLowBattery: Bool = true
    @AppStorage("lowBatteryThreshold") var lowBatteryThreshold: Int = 25
    @AppStorage("inactiveTimeOptions") private var inactiveTimeOptionsRaw: String = "1,2,5,10,15,30,45,60,75,90"

    private let inactiveTimeOptions: [Int] = [1, 2, 5, 10, 15, 30, 45, 60, 75, 90]
    private let sidetoneLabelWidth: CGFloat = 96
    private let sidetoneFieldWidth: CGFloat = 60

    private let sidetoneFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: -1)
        formatter.maximum = NSNumber(value: 128)
        return formatter
    }()

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

    private var updateIntervalSecondsBinding: Binding<Int> {
        Binding(
            get: { Int(updateInterval.rounded()) },
            set: { newValue in
                updateInterval = Double(min(max(newValue, 60), 3600))
            }
        )
    }

    private var lowBatteryThresholdBinding: Binding<Int> {
        Binding(
            get: { min(max(lowBatteryThreshold, 1), 30) },
            set: { newValue in
                lowBatteryThreshold = min(max(newValue, 1), 30)
            }
        )
    }

    private func clampedSidetoneBinding(_ binding: Binding<Int>) -> Binding<Int> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = min(max(newValue, -1), 128)
            }
        )
    }

    private func sidetoneRow(title: String, placeholder: String, value: Binding<Int>) -> some View {
        let clampedValue = clampedSidetoneBinding(value)

        return HStack(alignment: .center, spacing: 12) {
            Text(title)
                .frame(width: sidetoneLabelWidth, alignment: .trailing)

            TextField(placeholder, value: clampedValue, formatter: sidetoneFormatter)
                .frame(width: sidetoneFieldWidth)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)

            Stepper("", value: clampedValue, in: -1...128, step: 1)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsLabel(_ title: String) -> some View {
        Text(title)
            .foregroundColor(.secondary)
            .frame(width: 180, alignment: .trailing)
    }

    private var generalSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSection(
                    title: NSLocalizedString("General Settings", comment: "General settings section header"),
                    systemImage: "gearshape"
                ) {
                    HStack(alignment: .center, spacing: 12) {
                        settingsLabel(NSLocalizedString("Test Mode:", comment: "Test mode label"))
                        Picker("", selection: $testMode) {
                            Text(NSLocalizedString("1 - Error conditions", comment: "Test mode 1"))
                                .tag(1)
                            Text(NSLocalizedString("2 - Charging battery", comment: "Test mode 2"))
                                .tag(2)
                            Text(NSLocalizedString("3 - Basic battery", comment: "Test mode 3"))
                                .tag(3)
                            Text(NSLocalizedString("4 - Battery unavailable", comment: "Test mode 4"))
                                .tag(4)
                            Text(NSLocalizedString("5 - Timeout", comment: "Test mode 5"))
                                .tag(5)
                            Text(NSLocalizedString("6 - Full battery", comment: "Test mode 6"))
                                .tag(6)
                            Text(NSLocalizedString("7 - Low battery", comment: "Test mode 7"))
                                .tag(7)
                            Text(NSLocalizedString("Disabled", comment: "Test mode disabled"))
                                .tag(0)
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260, alignment: .leading)
                        .onChange(of: testMode) { _, _ in
                            NotificationCenter.default.post(name: .refreshHeadsetStatus, object: nil)
                        }
                    }

                    HStack(alignment: .center, spacing: 12) {
                        settingsLabel(NSLocalizedString("Update Interval (seconds):", comment: "Update interval label"))
                        Slider(value: $updateInterval, in: 60...3600, step: 30)
                        Text(String(format: NSLocalizedString("%d s", comment: "Update interval value in seconds"), updateIntervalSecondsBinding.wrappedValue))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                        Stepper("", value: updateIntervalSecondsBinding, in: 60...3600, step: 1)
                            .labelsHidden()
                    }
                }

                SettingsSection(
                    title: NSLocalizedString("Battery", comment: "Battery settings section header"),
                    systemImage: "battery.50"
                ) {
                    Toggle(NSLocalizedString("Notification on low battery", comment: "Low battery notification toggle label"), isOn: $notifyOnLowBattery)

                    HStack(alignment: .center, spacing: 12) {
                        settingsLabel(NSLocalizedString("Low battery threshold:", comment: "Low battery threshold label"))
                        Picker("", selection: lowBatteryThresholdBinding) {
                            ForEach(1...30, id: \.self) { value in
                                Text("\(value)%")
                                    .tag(value)
                            }
                        }
                        .frame(width: 90)
                        .pickerStyle(.menu)
                        .onChange(of: lowBatteryThreshold) { _, _ in
                            NotificationCenter.default.post(name: .refreshHeadsetStatus, object: nil)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var sidetoneSettingsTab: some View {
        ScrollView {
            SettingsSection(
                title: NSLocalizedString("Sidetone", comment: "Sidetone section header"),
                systemImage: "waveform"
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("Sidetone Level Values", comment: "Sidetone level info title"))
                    Text(NSLocalizedString("Valid range: -1...128. Use -1 to hide a menu entry.", comment: "Sidetone level range info"))
                }
                .font(.subheadline)
                .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    sidetoneRow(
                        title: NSLocalizedString("Off:", comment: "Sidetone off label"),
                        placeholder: NSLocalizedString("Off", comment: "Sidetone off field"),
                        value: $sidetoneOff
                    )
                    sidetoneRow(
                        title: NSLocalizedString("Low:", comment: "Sidetone low label"),
                        placeholder: NSLocalizedString("Low", comment: "Sidetone low field"),
                        value: $sidetoneLow
                    )
                    sidetoneRow(
                        title: NSLocalizedString("Medium:", comment: "Sidetone medium label"),
                        placeholder: NSLocalizedString("Medium", comment: "Sidetone medium field"),
                        value: $sidetoneMid
                    )
                    sidetoneRow(
                        title: NSLocalizedString("High:", comment: "Sidetone high label"),
                        placeholder: NSLocalizedString("High", comment: "Sidetone high field"),
                        value: $sidetoneHigh
                    )
                    sidetoneRow(
                        title: NSLocalizedString("Maximum:", comment: "Sidetone maximum label"),
                        placeholder: NSLocalizedString("Maximum", comment: "Sidetone maximum field"),
                        value: $sidetoneMax
                    )
                }
            }
            .padding(20)
        }
    }

    private var inactiveTimeSettingsTab: some View {
        ScrollView {
            SettingsSection(
                title: NSLocalizedString("Inactive Time", comment: "Inactive time options section header"),
                systemImage: "timer"
            ) {
                Text(NSLocalizedString("(Off is always included.)", comment: "Inactive time options help text"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(NSLocalizedString("Off", comment: "Inactive Time off option"))
                            .foregroundColor(.secondary)
                        Spacer()
                        Image(systemName: "checkmark")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 3)

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
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(20)
        }
    }

    private var equalizerSettingsTab: some View {
        ScrollView {
            SettingsSection(
                title: NSLocalizedString("Equalizer Presets", comment: "Equalizer presets section header"),
                systemImage: "slider.horizontal.3"
            ) {
                Text(NSLocalizedString("Comma-separated list of preset names.", comment: "Equalizer presets help text"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField(NSLocalizedString("Preset names", comment: "Equalizer presets text field label"), text: $equalizerPresets)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            }
            .padding(20)
        }
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

            Link(
                NSLocalizedString("GitHub Repository", comment: "GitHub link label"),
                destination: URL(string: "https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray")!
            )
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalSettingsTab
                    .tabItem {
                        Label(NSLocalizedString("General", comment: "General settings tab"), systemImage: "gearshape")
                    }

                sidetoneSettingsTab
                    .tabItem {
                        Label(NSLocalizedString("Sidetone", comment: "Sidetone tab"), systemImage: "waveform")
                    }

                inactiveTimeSettingsTab
                    .tabItem {
                        Label(NSLocalizedString("Inactive Time", comment: "Inactive time options tab"), systemImage: "timer")
                    }

                equalizerSettingsTab
                    .tabItem {
                        Label(NSLocalizedString("Equalizer Presets", comment: "Equalizer presets tab"), systemImage: "slider.horizontal.3")
                    }

                aboutTab
                    .tabItem {
                        Label(NSLocalizedString("About", comment: "About tab"), systemImage: "info.circle")
                    }
            }
            .frame(minWidth: 520, minHeight: 330)

            Divider()

            HStack(spacing: 8) {
                Spacer()
                Button(NSLocalizedString("Refresh", comment: "Refresh button")) {
                    NotificationCenter.default.post(name: .refreshHeadsetStatus, object: nil)
                }
                Button(NSLocalizedString("Close", comment: "Close button")) {
                    onClose?()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .background(.regularMaterial)
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
