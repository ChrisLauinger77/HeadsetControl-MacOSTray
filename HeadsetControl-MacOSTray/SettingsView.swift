import SwiftUI
import AppKit

struct AppIconImage: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let icon = AppIconProvider.image(isDark: colorScheme == .dark) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
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

@MainActor struct SettingsView: View {
    @Bindable var equalizer: EqualizerSettingsModel = EqualizerSettingsModel()
    @State private var nativeVersions: NativeDependencyVersions?
    @State private var requestedNativeVersions = false
    @State private var selectedLanguage = AppDefaults.selectedLanguage(
        in: AppDefaults.standard, domain: Bundle.main.bundleIdentifier ?? ""
    )
    @State private var languageRestartRequired = false
    @AppStorage("sidetoneOff", store: AppDefaults.standard) var sidetoneOff: Int = AppDefaults.sidetoneValues[0]
    @AppStorage("sidetoneLow", store: AppDefaults.standard) var sidetoneLow: Int = AppDefaults.sidetoneValues[1]
    @AppStorage("sidetoneMid", store: AppDefaults.standard) var sidetoneMid: Int = AppDefaults.sidetoneValues[2]
    @AppStorage("sidetoneHigh", store: AppDefaults.standard) var sidetoneHigh: Int = AppDefaults.sidetoneValues[3]
    @AppStorage("sidetoneMax", store: AppDefaults.standard) var sidetoneMax: Int = AppDefaults.sidetoneValues[4]
    @AppStorage("headsetVolumeOff", store: AppDefaults.standard) var headsetVolumeOff: Int = AppDefaults.headsetVolumeValues[0]
    @AppStorage("headsetVolumeLow", store: AppDefaults.standard) var headsetVolumeLow: Int = AppDefaults.headsetVolumeValues[1]
    @AppStorage("headsetVolumeMid", store: AppDefaults.standard) var headsetVolumeMid: Int = AppDefaults.headsetVolumeValues[2]
    @AppStorage("headsetVolumeHigh", store: AppDefaults.standard) var headsetVolumeHigh: Int = AppDefaults.headsetVolumeValues[3]
    @AppStorage("headsetVolumeMax", store: AppDefaults.standard) var headsetVolumeMax: Int = AppDefaults.headsetVolumeValues[4]
    @AppStorage("microphoneVolumeOff", store: AppDefaults.standard) var microphoneVolumeOff: Int = AppDefaults.microphoneVolumeValues[0]
    @AppStorage("microphoneVolumeLow", store: AppDefaults.standard) var microphoneVolumeLow: Int = AppDefaults.microphoneVolumeValues[1]
    @AppStorage("microphoneVolumeMid", store: AppDefaults.standard) var microphoneVolumeMid: Int = AppDefaults.microphoneVolumeValues[2]
    @AppStorage("microphoneVolumeHigh", store: AppDefaults.standard) var microphoneVolumeHigh: Int = AppDefaults.microphoneVolumeValues[3]
    @AppStorage("microphoneVolumeMax", store: AppDefaults.standard) var microphoneVolumeMax: Int = AppDefaults.microphoneVolumeValues[4]
    var onClose: (() -> Void)? = nil
    var onANCCommand: ((HeadsetCommand) -> Void)? = nil
    @AppStorage("bluetoothCallVolumeOff", store: AppDefaults.standard) var bluetoothCallVolumeOff: Int = AppDefaults.bluetoothCallVolumeValues[0]
    @AppStorage("bluetoothCallVolumeLow", store: AppDefaults.standard) var bluetoothCallVolumeLow: Int = AppDefaults.bluetoothCallVolumeValues[1]
    @AppStorage("bluetoothCallVolumeMid", store: AppDefaults.standard) var bluetoothCallVolumeMid: Int = AppDefaults.bluetoothCallVolumeValues[2]
    @AppStorage("bluetoothCallVolumeHigh", store: AppDefaults.standard) var bluetoothCallVolumeHigh: Int = AppDefaults.bluetoothCallVolumeValues[3]
    @AppStorage("bluetoothCallVolumeMax", store: AppDefaults.standard) var bluetoothCallVolumeMax: Int = AppDefaults.bluetoothCallVolumeValues[4]
    @AppStorage("updateInterval", store: AppDefaults.standard) var updateInterval: Double = Double(AppDefaults.updateInterval)
    @AppStorage("testMode", store: AppDefaults.standard) var testMode: Int = AppDefaults.testProfile
    @AppStorage("equalizerPresets", store: AppDefaults.standard) var equalizerPresets: String = AppDefaults.equalizerPresets
    @AppStorage("notifyOnLowBattery", store: AppDefaults.standard) var notifyOnLowBattery: Bool = AppDefaults.notifyOnLowBattery
    @AppStorage("showMicrophoneMuteIcon", store: AppDefaults.standard) var showMicrophoneMuteIcon: Bool = AppDefaults.showMicrophoneMuteIcon
    @AppStorage("lowBatteryThreshold", store: AppDefaults.standard) var lowBatteryThreshold: Int = AppDefaults.lowBatteryThreshold
    @AppStorage("inactiveTimeOptions", store: AppDefaults.standard) private var inactiveTimeOptionsRaw: String = AppDefaults.inactiveTimeOptionsRaw

    private let inactiveTimeOptions = AppDefaults.inactiveTimeOptions
    private let sidetoneLabelWidth: CGFloat = 96
    private let sidetoneFieldWidth: CGFloat = 60

    private let sidetoneFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: AppDefaults.sidetoneRange.lowerBound)
        formatter.maximum = NSNumber(value: AppDefaults.sidetoneRange.upperBound)
        return formatter
    }()

    private var normalizedInactiveTimeOptions: [Int] {
        AppDefaults.parseInactiveTimeOptions(inactiveTimeOptionsRaw)
    }

    private var selectedInactiveTimeMinutes: Set<Int> {
        Set(normalizedInactiveTimeOptions)
    }

    private var displayedEqualizerPresets: [String] {
        let presets = equalizerPresets
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let names = presets.isEmpty ? AppDefaults.equalizerPresets.split(separator: ",").map(String.init) : presets
        return names.map { NSLocalizedString($0, comment: "Equalizer fallback name") }
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

    private var appVersionInfo: ApplicationVersionInfo { ApplicationVersionInfo() }

    private var updateIntervalSecondsBinding: Binding<Int> {
        Binding(
            get: { AppDefaults.validatedUpdateInterval(updateInterval) },
            set: { newValue in
                updateInterval = Double(AppDefaults.validatedUpdateInterval(newValue))
            }
        )
    }

    private var lowBatteryThresholdBinding: Binding<Int> {
        Binding(
            get: { AppDefaults.validatedLowBatteryThreshold(lowBatteryThreshold) },
            set: { newValue in
                lowBatteryThreshold = AppDefaults.validatedLowBatteryThreshold(newValue)
            }
        )
    }

    private func clampedSidetoneBinding(_ binding: Binding<Int>) -> Binding<Int> {
        Binding(
            get: { AppDefaults.validatedSidetone(binding.wrappedValue, fallback: 0) },
            set: { newValue in
                binding.wrappedValue = AppDefaults.validatedSidetone(newValue, fallback: 0)
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

            Stepper("", value: clampedValue, in: AppDefaults.sidetoneRange, step: 1)
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
                    Toggle(NSLocalizedString("Show microphone mute status in the menu bar", comment: "Muted menu bar icon toggle"), isOn: $showMicrophoneMuteIcon)
                    HStack(alignment: .center, spacing: 12) {
                        settingsLabel(NSLocalizedString("Language:", comment: "App language label"))
                        Picker("", selection: $selectedLanguage) {
                            Text(NSLocalizedString("System", comment: "Follow the system language"))
                                .tag("")
                            Text(NSLocalizedString("English", comment: "English language name"))
                                .tag("en")
                            Text(NSLocalizedString("Deutsch", comment: "German language name"))
                                .tag("de")
                            Text(NSLocalizedString("Español", comment: "Spanish language name"))
                                .tag("es")
                            Text(NSLocalizedString("Français", comment: "French language name"))
                                .tag("fr")
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 260, alignment: .leading)
                        .onChange(of: selectedLanguage) { _, newValue in
                            AppDefaults.setLanguage(newValue, in: AppDefaults.standard)
                            languageRestartRequired = true
                        }
                    }
                    if languageRestartRequired {
                        Text(NSLocalizedString("Restart the app to apply the language change.", comment: "Language change restart notice"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        settingsLabel(NSLocalizedString("Test Mode:", comment: "Test mode label"))
                        Picker("", selection: Binding(get: { AppDefaults.validatedTestProfile(testMode) }, set: { testMode = AppDefaults.validatedTestProfile($0) })) {
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
                            Text(NSLocalizedString("10 - Limited capabilities", comment: "Test mode 10"))
                                .tag(10)
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
                        Slider(value: Binding(get: { Double(AppDefaults.validatedUpdateInterval(updateInterval)) },
                                              set: { updateInterval = Double(AppDefaults.validatedUpdateInterval($0)) }),
                               in: Double(AppDefaults.updateIntervalRange.lowerBound)...Double(AppDefaults.updateIntervalRange.upperBound), step: 30)
                        Text(String(format: NSLocalizedString("%d s", comment: "Update interval value in seconds"), updateIntervalSecondsBinding.wrappedValue))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                        Stepper("", value: updateIntervalSecondsBinding, in: AppDefaults.updateIntervalRange, step: 1)
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
                            ForEach(AppDefaults.lowBatteryThresholdRange, id: \.self) { value in
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

                ANCSettingsView(onCommand: onANCCommand)

                LightColorSettingsView()
            }
            .padding(20)
        }
    }

    private func volumePresetSettings(title: String, values: [Binding<Int>], range: ClosedRange<Int>, description: String? = nil) -> some View {
        SettingsSection(title: title, systemImage: "slider.horizontal.3") {
            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Text(String(format: NSLocalizedString("Valid range: -1...%d. Use -1 to hide a menu entry.", comment: "Configurable volume preset range"), range.upperBound))
                .font(.subheadline)
                .foregroundColor(.secondary)
            ForEach(values.indices, id: \.self) { index in
                let value = Binding(
                    get: { AppDefaults.validatedLevelPreset(values[index].wrappedValue, range: range, fallback: 0) },
                    set: { values[index].wrappedValue = AppDefaults.validatedLevelPreset($0, range: range, fallback: 0) }
                )
                HStack(spacing: 12) {
                    Text(NSLocalizedString(AppDefaults.levelPresetNames[index], comment: "Volume preset label"))
                        .frame(width: sidetoneLabelWidth, alignment: .trailing)
                    TextField("", value: value, formatter: volumePresetFormatter(range: range))
                        .frame(width: sidetoneFieldWidth)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Stepper("", value: value, in: range).labelsHidden()
                }
            }
        }
    }

    private func volumePresetFormatter(range: ClosedRange<Int>) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        return formatter
    }

    private var levelSettingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
                volumePresetSettings(title: NSLocalizedString("Headset volume", comment: "Hardware volume presets"),
                                     values: [$headsetVolumeOff, $headsetVolumeLow, $headsetVolumeMid, $headsetVolumeHigh, $headsetVolumeMax],
                                     range: AppDefaults.headsetVolumePresetRange,
                                     description: NSLocalizedString("Controls the headset's hardware volume.", comment: "Hardware volume settings explanation"))
                volumePresetSettings(title: NSLocalizedString("Microphone Volume", comment: "Microphone volume presets"),
                                     values: [$microphoneVolumeOff, $microphoneVolumeLow, $microphoneVolumeMid, $microphoneVolumeHigh, $microphoneVolumeMax],
                                     range: AppDefaults.microphoneVolumePresetRange)
                volumePresetSettings(title: NSLocalizedString("Bluetooth Call Volume", comment: "Bluetooth call volume presets"),
                                     values: [$bluetoothCallVolumeOff, $bluetoothCallVolumeLow, $bluetoothCallVolumeMid, $bluetoothCallVolumeHigh, $bluetoothCallVolumeMax],
                                     range: AppDefaults.bluetoothCallVolumePresetRange)
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
            VStack(spacing: 16) {
                SettingsSection(title: NSLocalizedString("Equalizer", comment: "Equalizer editor"), systemImage: "slider.horizontal.3") {
                    EqualizerSettingsView(model: equalizer)
                }
                SettingsSection(
                    title: NSLocalizedString("Equalizer Presets", comment: "Equalizer presets section header"),
                    systemImage: "slider.horizontal.3"
                ) {
                    Text(NSLocalizedString("Fallback names are used only for supported presets without a device-reported name.", comment: "Equalizer fallback names help"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(displayedEqualizerPresets, id: \.self) { preset in
                            HStack {
                                Text(preset)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .center, spacing: 16) {
            AppIconImage()
                .frame(width: 72, height: 72)
                .clipped()
                .shadow(radius: 4)

            Text(NSLocalizedString("HeadsetControl-MacOSTray", comment: "App title"))
                .font(.title2)
                .bold()

            VStack(spacing: 6) {
                Text(appVersionInfo.versionLine)
                Text(appVersionInfo.buildLine)
            }
            .font(.subheadline)
            .foregroundColor(.secondary)

            VStack(spacing: 4) {
                Text(verbatim: "HeadsetControl: \(nativeVersions?.headsetControlDisplay ?? NSLocalizedString("Unknown", comment: "Unknown native version"))")
                Text(verbatim: "HIDAPI: \(nativeVersions?.hidapiDisplay ?? NSLocalizedString("Unknown", comment: "Unknown native version"))")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Link(
                NSLocalizedString("GitHub Repository", comment: "GitHub link label"),
                destination: URL(string: "https://github.com/ChrisLauinger77/HeadsetControl-MacOSTray")!
            )
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onAppear {
            guard !requestedNativeVersions else { return }
            requestedNativeVersions = true
            HeadsetControlService.requestNativeVersions { nativeVersions = $0 }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $equalizer.settingsTab) {
                generalSettingsTab
                    .tabItem {
                        Label(NSLocalizedString("General", comment: "General settings tab"), systemImage: "gearshape")
                    }
                    .tag(0)

                levelSettingsTab
                    .tabItem {
                        Label(NSLocalizedString("Levels", comment: "Level presets tab"), systemImage: "waveform")
                    }
                    .tag(1)

                inactiveTimeSettingsTab
                    .tabItem {
                        Label(NSLocalizedString("Inactive Time", comment: "Inactive time options tab"), systemImage: "timer")
                    }
                    .tag(2)

                equalizerSettingsTab
                    .tabItem {
                        Label(NSLocalizedString("Equalizer", comment: "Equalizer tab"), systemImage: "slider.horizontal.3")
                    }
                    .tag(3)

                aboutTab
                    .tabItem {
                        Label(NSLocalizedString("About", comment: "About tab"), systemImage: "info.circle")
                    }
                    .tag(4)
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

struct ANCSettingsView: View {
    @AppStorage("ancStartupMode", store: AppDefaults.standard) private var startupMode = AppDefaults.ancStartupMode
    @AppStorage("ancButtonModes", store: AppDefaults.standard) private var buttonModesRaw = AppDefaults.ancButtonModes
    var onCommand: ((HeadsetCommand) -> Void)? = nil

    var startupModeBinding: Binding<Int> {
        Binding(
            get: { AppDefaults.validatedANCStartupMode(startupMode) },
            set: { newValue in
                let mode = AppDefaults.validatedANCStartupMode(newValue)
                guard mode != startupMode else { return }
                startupMode = mode
                applyStartupMode()
            }
        )
    }

    private var buttonModes: HeadsetANCButtonModes { AppDefaults.validatedANCButtonModes(buttonModesRaw) }

    func buttonModeBinding(_ mode: HeadsetANCButtonModes) -> Binding<Bool> {
        Binding(
            get: { buttonModes.contains(mode) },
            set: { enabled in
                let updated = buttonModes.setting(mode, enabled: enabled)
                guard updated != buttonModes else { return }
                buttonModesRaw = updated.rawValue
                applyButtonModes()
            }
        )
    }

    // Explicit submission also retries saved selections after reconnecting or a
    // failed write, without sending an unwanted intermediate configuration.
    func applyStartupMode() {
        onCommand?(.ancStartupMode(startupModeBinding.wrappedValue))
    }

    func applyButtonModes() {
        onCommand?(.ancButtonModes(buttonModes))
    }

    private func buttonModeToggle(_ title: String, mode: HeadsetANCButtonModes) -> some View {
        Toggle(title, isOn: buttonModeBinding(mode))
            .toggleStyle(.checkbox)
            .disabled(buttonModes == mode)
    }

    var body: some View {
        SettingsSection(title: NSLocalizedString("Noise cancelling", comment: "ANC settings section"), systemImage: "headphones") {
            Text(NSLocalizedString("Changes are sent to the first connected headset that supports each setting. Current values cannot be read from the headset.", comment: "Write-only ANC settings explanation"))
                .font(.caption)
                .foregroundColor(.secondary)
            Picker(NSLocalizedString("Mode at power-on:", comment: "ANC startup mode label"), selection: startupModeBinding) {
                Text(NSLocalizedString("Off", comment: "ANC startup off")).tag(0)
                Text(NSLocalizedString("Noise cancelling", comment: "ANC startup noise cancelling")).tag(1)
                Text(NSLocalizedString("Ambient sound", comment: "ANC startup ambient sound")).tag(2)
                Text(NSLocalizedString("Mode at power-off", comment: "Restore ANC mode at shutdown")).tag(3)
            }
            .pickerStyle(.menu)
            Button(NSLocalizedString("Apply startup mode", comment: "Send or retry the selected ANC startup mode"), action: applyStartupMode)
            Text(NSLocalizedString("ANC button cycles through:", comment: "ANC button cycle label"))
            HStack(spacing: 16) {
                buttonModeToggle(NSLocalizedString("Off", comment: "Include off in ANC cycle"), mode: .off)
                buttonModeToggle(NSLocalizedString("Noise cancelling", comment: "Include ANC in cycle"), mode: .anc)
                buttonModeToggle(NSLocalizedString("Ambient sound", comment: "Include ambient in ANC cycle"), mode: .ambient)
            }
            Button(NSLocalizedString("Apply button cycle", comment: "Send or retry the selected ANC button cycle"), action: applyButtonModes)
            Text(NSLocalizedString("Select at least one mode.", comment: "ANC button requires a nonempty cycle"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// Presets for the Lights menu. Nothing is sent from here: the headset cannot
// report its color, so a choice only takes effect from the menu.
struct LightColorSettingsView: View {
    @AppStorage("lightColor1", store: AppDefaults.standard) private var lightColor1 = AppDefaults.lightColorValues[0]
    @AppStorage("lightColor2", store: AppDefaults.standard) private var lightColor2 = AppDefaults.lightColorValues[1]
    @AppStorage("lightColor3", store: AppDefaults.standard) private var lightColor3 = AppDefaults.lightColorValues[2]
    @AppStorage("lightColor4", store: AppDefaults.standard) private var lightColor4 = AppDefaults.lightColorValues[3]

    private var presets: [Binding<Int>] { [$lightColor1, $lightColor2, $lightColor3, $lightColor4] }

    func preset(_ index: Int) -> HeadsetLightColor {
        HeadsetLightColor(rgb: AppDefaults.validatedLightColor(presets[index].wrappedValue, fallback: AppDefaults.lightColorValues[index]))
    }

    func colorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: preset(index).nsColor) },
            set: { newValue in
                guard let color = HeadsetLightColor(nsColor: NSColor(newValue)) else { return }
                presets[index].wrappedValue = color.rgb
            }
        )
    }

    var body: some View {
        SettingsSection(title: NSLocalizedString("Light Colors", comment: "Light color presets section"), systemImage: "lightbulb") {
            Text(NSLocalizedString("Colors offered in the Lights menu on headsets that support them. Choosing one also turns the lights on; black may turn them off.", comment: "Light color presets explanation"))
                .font(.subheadline)
                .foregroundColor(.secondary)
            ForEach(AppDefaults.lightColorKeys.indices, id: \.self) { index in
                let label = String(format: NSLocalizedString("Color %d:", comment: "Light color preset label"), index + 1)
                HStack(spacing: 12) {
                    Text(label)
                        .frame(width: 96, alignment: .trailing)
                    ColorPicker(label, selection: colorBinding(index), supportsOpacity: false)
                        .labelsHidden()
                    Text(verbatim: preset(index).hexString)
                        .monospaced()
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

extension HeadsetLightColor {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    // The color panel can return any color space; the headset takes sRGB bytes.
    init?(nsColor: NSColor) {
        guard let srgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> UInt8 { UInt8((max(0, min(1, component)) * 255).rounded()) }
        self.init(red: byte(srgb.redComponent), green: byte(srgb.greenComponent), blue: byte(srgb.blueComponent))
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
