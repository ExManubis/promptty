import Foundation

/// Renders `Settings` as the Ghostty config file libghostty loads (`terminal.conf`).
/// App-only settings (layout, sidebar, session, tint) are not written.
public enum TerminalConfigWriter {
    /// `knownThemes` nil skips theme validation; otherwise unknown themes fall back to Flexoki.
    /// `accentColor` (0xRRGGBB) is the system accent color, for an accent-colored cursor.
    public static func render(_ settings: Settings, knownThemes: Set<String>?, accentColor: UInt32? = nil) -> String {
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
        // The theme's cursor unless one was picked; the character under it in black or white.
        let cursorColor = settings.resolvedCursorColor(accent: accentColor).map {
            ["cursor-color = \(CursorColor.hex($0))", "cursor-text = \(CursorColor.hex(CursorColor.text(on: $0)))"]
        } ?? []
        let lines = [
            // Must stay first: PrompTTY's menus own every shortcut; libghostty binds nothing.
            "keybind = clear",
            "font-family = \(family.isEmpty ? "SF Mono" : family)",
            "font-size = \(format(settings.fontSize))",
            themeLine,
            "cursor-style = \(settings.cursorStyle.rawValue)",
            "cursor-style-blink = \(settings.cursorBlink)",
            // Shell integration would otherwise force a bar at every prompt, whatever the style.
            "shell-integration-features = no-cursor",
        ] + cursorColor + [
            "macos-option-as-alt = \(optionAsAlt)",
            "confirm-close-surface = \(settings.confirmCloseRunning)",
            "clipboard-read = \(settings.clipboardRead.rawValue)",
            "clipboard-write = \(settings.clipboardWrite.rawValue)",
            // The rounded pane card supplies the frame; keep the grid off its edges.
            "window-padding-x = 10",
            "window-padding-y = 8",
            "window-padding-balance = true",
            "window-padding-color = extend",
        ] + (settings.translucentPanes
            // The pane card draws the background, see-through; cells a program colors stay opaque.
            ? ["background-opacity = 0"]
            : [])
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
