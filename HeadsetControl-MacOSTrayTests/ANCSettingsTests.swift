import XCTest
@testable import HeadsetControl_MacOSTray

final class ANCSettingsTests: XCTestCase {
    func testDefaultsRepairInvalidValuesAndPreserveValidSelections() throws {
        let name = "ANCSettings.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        AppDefaults.register(in: store)
        XCTAssertEqual(store.integer(forKey: "ancStartupMode"), 3)
        XCTAssertEqual(store.integer(forKey: "ancButtonModes"), 7)
        for mode in 0...3 {
            store.set(mode, forKey: "ancStartupMode")
            AppDefaults.validate(in: store)
            XCTAssertEqual(store.integer(forKey: "ancStartupMode"), mode)
        }
        for modes in 1...7 {
            store.set(modes, forKey: "ancButtonModes")
            AppDefaults.validate(in: store)
            XCTAssertEqual(store.integer(forKey: "ancButtonModes"), modes)
        }
        for invalid: Any in [-1, 4, Int.max, 1.5, "invalid", true] {
            store.set(invalid, forKey: "ancStartupMode")
            AppDefaults.validate(in: store)
            XCTAssertEqual(store.integer(forKey: "ancStartupMode"), 3)
        }
        for invalid: Any in [0, -1, 8, Int.max, 1.5, "invalid", true] {
            store.set(invalid, forKey: "ancButtonModes")
            AppDefaults.validate(in: store)
            XCTAssertEqual(store.integer(forKey: "ancButtonModes"), 7)
        }
        for invalid: Any? in [nil, Double.nan, Double.infinity] {
            XCTAssertEqual(AppDefaults.validatedANCStartupMode(invalid), 3)
            XCTAssertEqual(AppDefaults.validatedANCButtonModes(invalid), .all)
        }
    }

    @MainActor func testCheckboxBindingsNeverClearLastModeAndOnlySendChanges() {
        let store = AppDefaults.standard
        let saved = store.object(forKey: "ancButtonModes")
        defer { store.set(saved, forKey: "ancButtonModes") }
        var commands: [HeadsetCommand] = []
        for rawValue in 1...7 {
            for mode: HeadsetANCButtonModes in [.off, .anc, .ambient] {
                for enabled in [false, true] {
                    store.set(rawValue, forKey: "ancButtonModes")
                    commands.removeAll()
                    let view = ANCSettingsView(onCommand: { commands.append($0) })
                    XCTAssertTrue(commands.isEmpty)
                    let old = HeadsetANCButtonModes(rawValue: rawValue)
                    let binding = view.buttonModeBinding(mode)
                    XCTAssertEqual(binding.wrappedValue, old.contains(mode))
                    binding.wrappedValue = enabled
                    let updated = HeadsetANCButtonModes(rawValue: store.integer(forKey: "ancButtonModes"))
                    XCTAssertTrue(updated.isValid)
                    if old == mode && !enabled {
                        XCTAssertEqual(updated, old)
                        XCTAssertTrue(binding.wrappedValue)
                        XCTAssertTrue(commands.isEmpty)
                    } else {
                        XCTAssertEqual(updated.contains(mode), enabled)
                        XCTAssertEqual(commands, updated == old ? [] : [.ancButtonModes(updated)])
                    }
                }
            }
        }
    }

    @MainActor func testStartupPickerSendsAllModesAndDoesNotSendOnCreation() {
        let store = AppDefaults.standard
        let saved = store.object(forKey: "ancStartupMode")
        defer { store.set(saved, forKey: "ancStartupMode") }
        store.set(3, forKey: "ancStartupMode")
        var commands: [HeadsetCommand] = []
        let view = ANCSettingsView(onCommand: { commands.append($0) })
        XCTAssertTrue(commands.isEmpty)
        let binding = view.startupModeBinding
        XCTAssertEqual(binding.wrappedValue, 3)
        for mode in 0...3 {
            binding.wrappedValue = mode
            XCTAssertEqual(store.integer(forKey: "ancStartupMode"), mode)
        }
        XCTAssertEqual(commands, (0...3).map(HeadsetCommand.ancStartupMode))
        binding.wrappedValue = 3
        XCTAssertEqual(commands.count, 4)
    }

    @MainActor func testApplyResendsSavedValuesIndependentlyWithoutEditingThem() {
        let store = AppDefaults.standard
        let savedStartup = store.object(forKey: "ancStartupMode")
        let savedCycle = store.object(forKey: "ancButtonModes")
        defer {
            store.set(savedStartup, forKey: "ancStartupMode")
            store.set(savedCycle, forKey: "ancButtonModes")
        }
        store.set(2, forKey: "ancStartupMode")
        store.set(HeadsetANCButtonModes.anc.rawValue, forKey: "ancButtonModes")
        var commands: [HeadsetCommand] = []
        let view = ANCSettingsView(onCommand: { commands.append($0) })
        XCTAssertTrue(commands.isEmpty)
        view.applyStartupMode()
        view.applyStartupMode()
        XCTAssertEqual(commands, [.ancStartupMode(2), .ancStartupMode(2)])
        view.applyButtonModes()
        view.applyButtonModes()
        XCTAssertEqual(commands, [.ancStartupMode(2), .ancStartupMode(2), .ancButtonModes(.anc), .ancButtonModes(.anc)])
        XCTAssertEqual(store.integer(forKey: "ancStartupMode"), 2)
        XCTAssertEqual(store.integer(forKey: "ancButtonModes"), HeadsetANCButtonModes.anc.rawValue)
    }
}
