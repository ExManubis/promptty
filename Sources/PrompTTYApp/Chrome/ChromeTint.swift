import AppKit

/// Window colors. The frame takes the selected theme's background color, darker than the panes so
/// they stand out on it; the "Frame color" setting turns it down to a neutral gray.
enum ChromeTint {
    /// Dia's neutral frame, laid over the behind-window blur: near-black in dark mode, a soft
    /// gray in light mode (so white selected rows stand out). Partly transparent, so the
    /// blurred desktop tints it slightly.
    static let fallback = NSColor(name: "PrompTTYFrame") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: frameDark, green: frameDark, blue: frameDark, alpha: frameAlphaDark)
            : NSColor(srgbRed: frameLight, green: frameLight, blue: frameLight + 0.006, alpha: frameAlphaLight)
    }

    // The tint over the blurred desktop: frosted glass, as Rex's, dark enough for the panes on it to
    // read while the wallpaper's color comes through the frame and, fainter, the panes.
    static let frameDark: CGFloat = 0.09
    static let frameLight: CGFloat = 0.93
    /// How opaque the tint over the blur is; the rest is blurred desktop.
    static let frameAlphaDark: CGFloat = 0.45
    static let frameAlphaLight: CGFloat = 0.30

    /// A theme-tinted frame over the blur, with the same transparency as the neutral one.
    static func overBlur(_ color: NSColor) -> NSColor {
        color.withAlphaComponent(isDark(color) ? themeAlphaDark : themeAlphaLight)
    }

    /// A theme's frame is more opaque than the neutral one, so the theme's hue holds against the
    /// desktop behind it.
    static var themeAlphaDark: CGFloat { debugValue("PROMPTTY_FRAME_ALPHA") ?? 0.6 }
    static var themeAlphaLight: CGFloat { debugValue("PROMPTTY_FRAME_ALPHA_LIGHT") ?? frameAlphaLight }
    /// How much more saturated than the theme background the frame is.
    static var themeSaturation: CGFloat { debugValue("PROMPTTY_FRAME_SAT") ?? 1.6 }

    private static func debugValue(_ name: String) -> CGFloat? {
        #if DEBUG
        ProcessInfo.processInfo.environment[name].flatMap(Double.init).map { CGFloat($0) }
        #else
        nil
        #endif
    }

    /// The frame color for a theme background, or nil for the neutral system color.
    /// `strength` (0…1) is how much of the theme's hue the frame keeps; 0 is neutral.
    static func frame(forTerminalBackground bg: NSColor, strength: Double) -> NSColor? {
        guard strength > 0 else { return nil }
        return tint(forTerminalBackground: bg, strength: strength)
    }

    /// The theme background's own hue, a shade darker than the panes so they stand out on it (as
    /// Rex's do), and in dark themes never darker than the neutral frame. `strength` is how much of
    /// the hue's saturation it keeps.
    static func tint(forTerminalBackground bg: NSColor, strength: Double = 1) -> NSColor {
        guard let rgb = bg.usingColorSpace(.sRGB) else { return fallback }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let keep = CGFloat(min(1, max(0, strength)))
        let brightness = isDark(rgb) ? max(frameDark, b * frameShadeDark) : b * frameShadeLight
        return NSColor(hue: h, saturation: min(1, s * themeSaturation) * keep, brightness: brightness, alpha: 1).usingColorSpace(.sRGB) ?? fallback
    }

    /// How much of a theme background's brightness the frame keeps.
    static let frameShadeDark: CGFloat = 0.72
    static let frameShadeLight: CGFloat = 0.96

    static func isDark(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.5
    }
}
