import AppKit

enum AppIconProvider {
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
