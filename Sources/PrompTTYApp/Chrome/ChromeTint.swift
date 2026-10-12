import AppKit

/// Arc-style chrome: a solid backdrop derived from the terminal theme's background.
enum ChromeTint {
    static let fallback = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.90, alpha: 1)

    /// Dark themes get a slightly lighter frame; light themes a slightly darker one, so the
    /// terminal card always reads as inset. `strength` (0…1) is how much of the theme's hue the
    /// frame keeps: 0 is a neutral gray of the same lightness, 1 the theme's own color.
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
