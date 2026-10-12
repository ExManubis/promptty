import Foundation

public struct RGB: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }

    /// "#rrggbb" or "rrggbb".
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8((value >> 16) & 0xff), g: UInt8((value >> 8) & 0xff), b: UInt8(value & 0xff))
    }

    /// Relative luminance (sRGB, not linearized), 0…1.
    public var luminance: Double {
        (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
    }
}

public struct ThemeSwatch: Equatable, Sendable {
    public var background: RGB
    public var foreground: RGB
    /// Palette index 0–15 → color, for the entries the theme defines.
    public var palette: [Int: RGB]
}

/// The Ghostty themes bundled with libghostty (one file per theme, named after the theme).
public struct ThemeCatalog: Sendable {
    public static let fallbackLight = "Flexoki Light"
    public static let fallbackDark = "Flexoki Dark"

    public let directory: URL
    public let names: [String]

    public init(directory: URL) {
        self.directory = directory
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        names = entries
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
    }

    public func contains(_ name: String) -> Bool { names.contains(name) }

    public func swatch(for name: String) -> ThemeSwatch? {
        guard contains(name),
              let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { return nil }
        return Self.parse(text)
    }

    /// Reads `background`, `foreground` and `palette = N=#rrggbb` lines from a Ghostty theme file.
    public static func parse(_ contents: String) -> ThemeSwatch? {
        var background: RGB?
        var foreground: RGB?
        var palette: [Int: RGB] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "background": background = RGB(hex: parts[1])
            case "foreground": foreground = RGB(hex: parts[1])
            case "palette":
                let entry = parts[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if entry.count == 2, let index = Int(entry[0]), (0...15).contains(index), let color = RGB(hex: entry[1]) {
                    palette[index] = color
                }
            default: continue
            }
        }
        guard let background, let foreground else { return nil }
        return ThemeSwatch(background: background, foreground: foreground, palette: palette)
    }
}
