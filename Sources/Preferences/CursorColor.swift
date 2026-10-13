import Foundation

/// The cursor's color: the theme's own, the system accent color, or one the user picked. Saved
/// as "theme", "accent" or "#RRGGBB".
public enum CursorColor: Equatable, Sendable {
    case theme
    case accent
    /// 0xRRGGBB.
    case custom(UInt32)

    var stringValue: String {
        switch self {
        case .theme: "theme"
        case .accent: "accent"
        case .custom(let rgb): Self.hex(rgb)
        }
    }

    /// Nil for anything else.
    init?(stringValue: String) {
        switch stringValue {
        case "theme": self = .theme
        case "accent": self = .accent
        default:
            guard stringValue.count == 7, stringValue.hasPrefix("#"),
                  let rgb = UInt32(stringValue.dropFirst(), radix: 16) else { return nil }
            self = .custom(rgb)
        }
    }

    static func hex(_ rgb: UInt32) -> String {
        "#" + String(format: "%06X", rgb & 0xFFFFFF)
    }

    /// Black or white, whichever contrasts more with `rgb`: the character under a block cursor.
    public static func text(on rgb: UInt32) -> UInt32 {
        func linear(_ c: UInt32) -> Double {
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * linear((rgb >> 16) & 0xFF) + 0.7152 * linear((rgb >> 8) & 0xFF) + 0.0722 * linear(rgb & 0xFF)
        // Contrast with white is 1.05 / (l + 0.05), with black (l + 0.05) / 0.05.
        return 1.05 / (l + 0.05) >= (l + 0.05) / 0.05 ? 0xFFFFFF : 0x000000
    }
}

extension Settings {
    /// The cursor's color as 0xRRGGBB, nil for the theme's. `accent` is the system accent color
    /// (nil when not known).
    public func resolvedCursorColor(accent: UInt32?) -> UInt32? {
        switch cursorColor {
        case .theme: nil
        case .accent: accent
        case .custom(let rgb): rgb
        }
    }
}
