import AppKit

enum AppIconProvider {
    enum StatusIcon: String {
        case headset = "headset"
        case microphoneMuted = "mic.slash.fill"
    }

    // Selection uses cached telemetry only. Failed/unsupported reads report no state.
    static func statusIcon(muteStatuses: [Result<Bool, HeadsetFailure>?], showMuted: Bool) -> StatusIcon {
        guard showMuted else { return .headset }
        for status in muteStatuses {
            if case .success(let muted) = status { return muted ? .microphoneMuted : .headset }
        }
        return .headset
    }

    static func image(for statusIcon: StatusIcon) -> NSImage? {
        let description = statusIcon == .microphoneMuted
            ? NSLocalizedString("Microphone muted", comment: "Muted microphone icon accessibility description")
            : NSLocalizedString("Headset", comment: "Headset icon accessibility description")
        let image = NSImage(systemSymbolName: statusIcon.rawValue, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    static func image(isDark: Bool) -> NSImage? {
        let assetName = isDark ? "AppIconDark" : "AppIconLight"

        #if SWIFT_PACKAGE
        guard let url = Bundle.module.url(
            forResource: assetName,
            withExtension: "png",
            subdirectory: "Assets.xcassets/\(assetName).imageset"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
        #else
        return NSImage(named: NSImage.Name(assetName))
        #endif
    }
}
