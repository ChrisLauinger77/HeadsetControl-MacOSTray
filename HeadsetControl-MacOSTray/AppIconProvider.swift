import AppKit

enum AppIconProvider {
    static func image(isDark: Bool) -> NSImage? {
        let name = NSImage.Name(isDark ? "AppIconDark" : "AppIconLight")

        #if SWIFT_PACKAGE
        return Bundle.module.image(forResource: name)
        #else
        return NSImage(named: name)
        #endif
    }
}
