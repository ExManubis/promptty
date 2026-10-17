import AppKit

/// Window colors. By default the frame is the system's neutral window color (Dia-style); the
/// "Frame color" setting blends in the terminal theme's background instead.
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
    static let frameAlphaDark: CGFloat = 0.50
    static let frameAlphaLight: CGFloat = 0.38

    /// A theme-tinted frame over the blur, with the same transparency as the neutral one.
    static func overBlur(_ color: NSColor) -> NSColor {
        color.withAlphaComponent(isDark(color) ? frameAlphaDark : frameAlphaLight)
    }

    /// The frame color for a theme background, or nil for the neutral system color.
    /// `strength` (0…1) is how much of the theme's hue the frame keeps; 0 is neutral.
    static func frame(forTerminalBackground bg: NSColor, strength: Double) -> NSColor? {
        guard strength > 0 else { return nil }
        return tint(forTerminalBackground: bg, strength: strength)
    }

    /// Dark themes get a slightly lighter frame, light themes a slightly darker one, so the
    /// content panel always reads as inset.
    static func tint(forTerminalBackground bg: NSColor, strength: Double = 1) -> NSColor {
        guard let rgb = bg.usingColorSpace(.sRGB) else { return fallback }
        let dark = isDark(rgb)
        let target: NSColor = dark ? .white : .black
        let amount: CGFloat = dark ? 0.12 : 0.07
        guard let shifted = rgb.blended(withFraction: amount, of: target)?.usingColorSpace(.sRGB) else { return fallback }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        shifted.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let keep = CGFloat(min(1, max(0, strength)))
        return NSColor(hue: h, saturation: s * keep, brightness: b, alpha: 1).usingColorSpace(.sRGB) ?? shifted
    }

    static func isDark(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.5
    }
}
