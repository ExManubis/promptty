import AppKit

/// Arc-style chrome: a tinted frame derived from the terminal theme's background.
enum ChromeTint {
    static let fallback = NSColor(calibratedRed: 0.81, green: 0.80, blue: 0.96, alpha: 1)

    /// Dark themes get a slightly lighter frame; light themes a slightly darker one, so the
    /// terminal card always reads as inset.
    static func tint(forTerminalBackground bg: NSColor) -> NSColor {
        guard let rgb = bg.usingColorSpace(.sRGB) else { return fallback }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        let target: NSColor = luminance < 0.5 ? .white : .black
        let amount: CGFloat = luminance < 0.5 ? 0.12 : 0.07
        return rgb.blended(withFraction: amount, of: target) ?? fallback
    }
}
