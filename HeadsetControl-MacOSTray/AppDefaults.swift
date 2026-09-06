import Foundation

// Shared policy for registration, persisted-value repair and UI bindings.
nonisolated enum AppDefaults {
    static let sidetoneKeys = ["sidetoneOff", "sidetoneLow", "sidetoneMid", "sidetoneHigh", "sidetoneMax"]
    static let sidetoneValues = [0, 32, 64, 96, 128]
    static let sidetoneRange = -1...128
    static let updateInterval = 600
    static let updateIntervalRange = 60...3600
    static let snapshotFreshnessGrace: TimeInterval = 60
    static let testProfile = 0
    static let testProfileRange = 0...7
    static let lowBatteryThreshold = 25
    static let lowBatteryThresholdRange = 1...30
    static let notifyOnLowBattery = true
    static let equalizerPresets = "Preset 1,Preset 2,Preset 3,Preset 4"
    static let inactiveTimeOptions = [1, 2, 5, 10, 15, 30, 45, 60, 75, 90]
    static var inactiveTimeOptionsRaw: String { inactiveTimeOptions.map(String.init).joined(separator: ",") }

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
            "equalizerPresets": equalizerPresets, "inactiveTimeOptions": inactiveTimeOptionsRaw
        ]
        for (key, value) in zip(sidetoneKeys, sidetoneValues) { values[key] = value }
        store.register(defaults: values)
        validate(in: store)
    }

    static func validate(in store: UserDefaults) {
        if store.object(forKey: "notifyOnLowBattery") as? Bool == nil {
            store.set(notifyOnLowBattery, forKey: "notifyOnLowBattery")
        }
        repair("updateInterval", value: validatedUpdateInterval(store.object(forKey: "updateInterval")), in: store)
        repair("testMode", value: validatedTestProfile(store.object(forKey: "testMode")), in: store)
        repair("lowBatteryThreshold", value: validatedLowBatteryThreshold(store.object(forKey: "lowBatteryThreshold")), in: store)
        for (key, fallback) in zip(sidetoneKeys, sidetoneValues) {
            repair(key, value: validatedSidetone(store.object(forKey: key), fallback: fallback), in: store)
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

    static func validatedTestProfile(_ value: Any?) -> Int {
        guard let number = finiteNumber(value), number.rounded() == number,
              Double(testProfileRange.lowerBound)...Double(testProfileRange.upperBound) ~= number else { return testProfile }
        return Int(number)
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
