import AppKit
import CoreText

/// macOS ships SF Mono inside Terminal.app but does not always register it for lookup by family
/// name, which is how libghostty finds fonts. Registering the system copy for this process only
/// makes `font-family = SF Mono` work everywhere. Nothing is copied or installed.
enum FontRegistration {
    static func ensureSFMono() {
        guard NSFontManager.shared.availableMembers(ofFontFamily: "SF Mono") == nil else { return }
        let dir = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.lastPathComponent.hasPrefix("SF-Mono") {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                NSLog("PrompTTY: could not register \(url.lastPathComponent): \(String(describing: error?.takeRetainedValue()))")
            }
        }
    }
}
