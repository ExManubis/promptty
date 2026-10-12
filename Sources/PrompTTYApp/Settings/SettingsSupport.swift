import AppKit
import Observation
import Preferences
import SwiftUI

/// Installed monospaced font families, for the font picker. SF Mono is always offered.
enum MonospacedFonts {
    static func families() -> [String] {
        var names = Set<String>()
        for fontName in NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [] {
            guard let family = NSFont(name: fontName, size: 12)?.familyName, !family.hasPrefix(".") else { continue }
            names.insert(family)
        }
        names.insert("SF Mono")
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func isInstalled(_ family: String) -> Bool {
        NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
    }
}

/// Theme swatches read lazily from the bundled theme files and cached.
@MainActor
final class ThemeSwatches {
    let catalog: ThemeCatalog
    private var cache: [String: ThemeSwatch?] = [:]

    init(catalog: ThemeCatalog) { self.catalog = catalog }

    func swatch(for name: String) -> ThemeSwatch? {
        if let cached = cache[name] { return cached }
        let s = catalog.swatch(for: name)
        cache[name] = s
        return s
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}

/// A theme's background with its foreground and first six palette colors on top.
struct ThemeSwatchView: View {
    let swatch: ThemeSwatch?

    var body: some View {
        HStack(spacing: 2) {
            if let swatch {
                Text("Aa")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(swatch.foreground))
                    .padding(.trailing, 2)
                ForEach(1...6, id: \.self) { i in
                    Circle()
                        .fill(swatch.palette[i].map(Color.init) ?? .clear)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(.horizontal, 6)
        .fixedSize()
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(swatch.map { Color($0.background) } ?? Color.secondary.opacity(0.2))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }
}
