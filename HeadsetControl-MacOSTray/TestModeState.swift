import Observation

@MainActor @Observable final class TestModeState {
    private var selectedProfile = AppDefaults.testProfile

    var profile: Int {
        get { selectedProfile }
        set { selectedProfile = AppDefaults.validatedTestProfile(newValue) }
    }
}
