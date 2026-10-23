import Foundation

// Shared policy for registration, persisted-value repair and UI bindings.
nonisolated enum AppDefaults {
    static let sidetoneKeys = ["sidetoneOff", "sidetoneLow", "sidetoneMid", "sidetoneHigh", "sidetoneMax"]
    static let sidetoneValues = [0, 32, 64, 96, 128]
    static let sidetoneRange = -1...128
    static let levelPresetNames = ["Off", "Low", "Medium", "High", "Maximum"]
    static let microphoneVolumeKeys = ["microphoneVolumeOff", "microphoneVolumeLow", "microphoneVolumeMid", "microphoneVolumeHigh", "microphoneVolumeMax"]
    static let microphoneVolumeValues = [0, 32, 64, 96, 128]
    static let microphoneVolumeRange = 0...128
    static let noiseFilterRange = 0...2
    static let ancRange = 0...2
    static let ancStartupModeRange = 0...3
    static let ancStartupMode = 3
    static let ancButtonModes = HeadsetANCButtonModes.all.rawValue
    static let microphoneMuteLedBrightnessRange = 0...3
    static let microphoneVolumePresetRange = -1...128
    static let bluetoothCallVolumeKeys = ["bluetoothCallVolumeOff", "bluetoothCallVolumeLow", "bluetoothCallVolumeMid", "bluetoothCallVolumeHigh", "bluetoothCallVolumeMax"]
    static let bluetoothCallVolumeValues = [0, 25, 50, 75, 100]
    static let bluetoothCallVolumeRange = 0...100
    static let bluetoothCallVolumePresetRange = -1...100
    static let updateInterval = 600
    static let updateIntervalRange = 60...3600
    static let snapshotFreshnessGrace: TimeInterval = 60
    static let testProfile = 0
    static let testProfileRange = 0...7
    static let lowBatteryThreshold = 25
    static let lowBatteryThresholdRange = 1...30
    static let notifyOnLowBattery = true
    static let showMicrophoneMuteIcon = true
    static let equalizerPresets = "Preset 1,Preset 2,Preset 3,Preset 4"
    static let inactiveTimeOptions = [1, 2, 5, 10, 15, 30, 45, 60, 75, 90]
    static var inactiveTimeOptionsRaw: String { inactiveTimeOptions.map(String.init).joined(separator: ",") }
    static let supportedLanguages = ["en", "de", "es", "fr"]

    static func selectedLanguage(in store: UserDefaults, domain: String) -> String {
        guard let languages = store.persistentDomain(forName: domain)?["AppleLanguages"] as? [String],
              let language = languages.first, supportedLanguages.contains(language) else { return "" }
        return language
    }

    static func setLanguage(_ language: String, in store: UserDefaults) {
        if supportedLanguages.contains(language) {
            store.set([language], forKey: "AppleLanguages")
        } else {
            store.removeObject(forKey: "AppleLanguages")
        }
    }

    // Evaluated before any @AppStorage access, including Settings previews.
    static let standard: UserDefaults = {
        let store = UserDefaults.standard
        register(in: store)
        return store
    }()

    static func register(in store: UserDefaults) {
        var values: [String: Any] = [
            "updateInterval": Double(updateInterval), "testMode": testProfile,
            "notifyOnLowBattery": notifyOnLowBattery, "lowBatteryThreshold": lowBatteryThreshold,
            "showMicrophoneMuteIcon": showMicrophoneMuteIcon,
            "ancStartupMode": ancStartupMode, "ancButtonModes": ancButtonModes,
            "equalizerPresets": equalizerPresets, "inactiveTimeOptions": inactiveTimeOptionsRaw
        ]
        for (key, value) in zip(sidetoneKeys, sidetoneValues) { values[key] = value }
        for (key, value) in zip(microphoneVolumeKeys, microphoneVolumeValues) { values[key] = value }
        for (key, value) in zip(bluetoothCallVolumeKeys, bluetoothCallVolumeValues) { values[key] = value }
        store.register(defaults: values)
        validate(in: store)
    }

    static func validate(in store: UserDefaults) {
        if store.object(forKey: "showMicrophoneMuteIcon") as? Bool == nil {
            store.set(showMicrophoneMuteIcon, forKey: "showMicrophoneMuteIcon")
        }
        if store.object(forKey: "notifyOnLowBattery") as? Bool == nil {
            store.set(notifyOnLowBattery, forKey: "notifyOnLowBattery")
        }
        repair("updateInterval", value: validatedUpdateInterval(store.object(forKey: "updateInterval")), in: store)
        repair("testMode", value: validatedTestProfile(store.object(forKey: "testMode")), in: store)
        repair("ancStartupMode", value: validatedANCStartupMode(store.object(forKey: "ancStartupMode")), in: store)
        repair("ancButtonModes", value: validatedANCButtonModes(store.object(forKey: "ancButtonModes")).rawValue, in: store)
        repair("lowBatteryThreshold", value: validatedLowBatteryThreshold(store.object(forKey: "lowBatteryThreshold")), in: store)
        for (key, fallback) in zip(sidetoneKeys, sidetoneValues) {
            repair(key, value: validatedSidetone(store.object(forKey: key), fallback: fallback), in: store)
        }
        for (key, fallback) in zip(microphoneVolumeKeys, microphoneVolumeValues) {
            repair(key, value: validatedLevelPreset(store.object(forKey: key), range: microphoneVolumePresetRange, fallback: fallback), in: store)
        }
        for (key, fallback) in zip(bluetoothCallVolumeKeys, bluetoothCallVolumeValues) {
            repair(key, value: validatedLevelPreset(store.object(forKey: key), range: bluetoothCallVolumePresetRange, fallback: fallback), in: store)
        }
    }

    static func validatedUpdateInterval(_ value: Any?) -> Int {
        boundedInteger(value, range: updateIntervalRange, fallback: updateInterval)
    }

    static func snapshotMaximumAge(for updateInterval: Any?) -> TimeInterval {
        TimeInterval(validatedUpdateInterval(updateInterval)) + snapshotFreshnessGrace
    }

    static func validatedLowBatteryThreshold(_ value: Any?) -> Int {
        boundedInteger(value, range: lowBatteryThresholdRange, fallback: lowBatteryThreshold)
    }

    static func validatedSidetone(_ value: Any?, fallback: Int) -> Int {
        boundedInteger(value, range: sidetoneRange, fallback: fallback)
    }

    static func validatedLevelPreset(_ value: Any?, range: ClosedRange<Int>, fallback: Int) -> Int {
        boundedInteger(value, range: range, fallback: fallback)
    }

    static func validatedTestProfile(_ value: Any?) -> Int {
        guard let number = finiteNumber(value), number.rounded() == number,
              Double(testProfileRange.lowerBound)...Double(testProfileRange.upperBound) ~= number else { return testProfile }
        return Int(number)
    }

    static func validatedANCStartupMode(_ value: Any?) -> Int {
        guard let number = finiteNumber(value), number.rounded() == number,
              Double(ancStartupModeRange.lowerBound)...Double(ancStartupModeRange.upperBound) ~= number else { return ancStartupMode }
        return Int(number)
    }

    static func validatedANCButtonModes(_ value: Any?) -> HeadsetANCButtonModes {
        guard let number = finiteNumber(value), number.rounded() == number,
              (1...Double(ancButtonModes)).contains(number) else { return .all }
        return HeadsetANCButtonModes(rawValue: Int(number))
    }

    static func parseInactiveTimeOptions(_ raw: String) -> [Int] {
        let allowed = Set(inactiveTimeOptions)
        return Array(Set(raw.split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { allowed.contains($0) })).sorted()
    }

    static func presetName(index: Int, fallbackNames: String) -> String {
        let names = fallbackNames.split(separator: ",", omittingEmptySubsequences: false)
        if names.indices.contains(index) {
            let name = names[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return NSLocalizedString(name, comment: "Configured fallback preset name") }
        }
        return String(format: NSLocalizedString("Preset %d", comment: "Unnamed native preset"), index + 1)
    }

    private static func boundedInteger(_ value: Any?, range: ClosedRange<Int>, fallback: Int) -> Int {
        guard let number = finiteNumber(value) else { return fallback }
        // Clamp as Double BEFORE conversion, including persisted Int.max values.
        return Int(min(max(number.rounded(), Double(range.lowerBound)), Double(range.upperBound)))
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func repair(_ key: String, value: Int, in store: UserDefaults) {
        if finiteNumber(store.object(forKey: key)) != Double(value) { store.set(value, forKey: key) }
    }
}
