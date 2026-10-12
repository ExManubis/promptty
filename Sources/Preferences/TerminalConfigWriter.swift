import Foundation

/// Renders `Settings` as the Ghostty config file libghostty loads (`terminal.conf`).
/// App-only settings (layout, sidebar, session, tint) are not written.
public enum TerminalConfigWriter {
    /// `knownThemes` nil skips theme validation; otherwise unknown themes fall back to Flexoki.
    public static func render(_ settings: Settings, knownThemes: Set<String>?) -> String {
        func theme(_ name: String, fallback: String) -> String {
            let clean = sanitize(name)
            guard let knownThemes else { return clean }
            return knownThemes.contains(clean) ? clean : fallback
        }
        let family = sanitize(settings.fontFamily).trimmingCharacters(in: .whitespaces)
        let themeLine: String
        if settings.followSystemAppearance {
            let light = theme(settings.lightTheme, fallback: ThemeCatalog.fallbackLight)
            let dark = theme(settings.darkTheme, fallback: ThemeCatalog.fallbackDark)
            themeLine = "theme = light:\(light),dark:\(dark)"
        } else {
            themeLine = "theme = \(theme(settings.theme, fallback: ThemeCatalog.fallbackDark))"
        }
        let optionAsAlt: String
        switch settings.optionAsAlt {
        case .both: optionAsAlt = "true"
        case .left: optionAsAlt = "left"
        case .right: optionAsAlt = "right"
        case .off: optionAsAlt = "false"
        }
        let lines = [
            // Must stay first: PrompTTY's menus own every shortcut; libghostty binds nothing.
            "keybind = clear",
            "font-family = \(family.isEmpty ? "SF Mono" : family)",
            "font-size = \(format(settings.fontSize))",
            themeLine,
            "cursor-style = \(settings.cursorStyle.rawValue)",
            "cursor-style-blink = \(settings.cursorBlink)",
            "macos-option-as-alt = \(optionAsAlt)",
            "confirm-close-surface = \(settings.confirmCloseRunning)",
            // The rounded pane card supplies the frame; keep the grid off its edges.
            "window-padding-x = 10",
            "window-padding-y = 8",
            "window-padding-balance = true",
            "window-padding-color = extend",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Values are single-line: strip anything that would end the line.
    private static func sanitize(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.newlines.contains($0) && $0 != "\0" })
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
