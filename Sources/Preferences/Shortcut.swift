import Foundation

/// A keyboard shortcut such as ⇧⌘D, stored as a canonical string ("shift+cmd+d").
public struct Shortcut: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// Named keys, then single printable characters.
    public static let namedKeys: Set<String> = ["left", "right", "up", "down", "return", "tab", "delete", "escape", "space"]

    /// A single lowercase character ("d", "[", "=") or one of `namedKeys`.
    public let key: String
    public let modifiers: Modifiers

    public init?(key: String, modifiers: Modifiers) {
        let key = key.lowercased()
        guard Self.namedKeys.contains(key) || (key.count == 1 && !key.contains("+") && !key.trimmingCharacters(in: .whitespaces).isEmpty) else { return nil }
        self.key = key
        self.modifiers = modifiers
    }

    /// Parses "cmd+shift+d", "opt+cmd+left", "ctrl+cmd+=". Modifier names: cmd, shift, opt (or alt), ctrl.
    public init?(string: String) {
        // "cmd++" would be ambiguous; "+" itself is not a supported key.
        let parts = string.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let last = parts.last, !last.isEmpty else { return nil }
        var mods: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "alt", "option": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: return nil
            }
        }
        self.init(key: last, modifiers: mods)
    }

    public var containsCommand: Bool { modifiers.contains(.command) }

    /// Canonical form, modifiers in Apple's display order (⌃⌥⇧⌘).
    public var string: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    public var description: String { string }

    public var displayString: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + keyDisplay
    }

    /// The string for `NSMenuItem.keyEquivalent`. AppKit compares it with the event's
    /// shift-applied character, so shifted letters are uppercase; named keys use AppKit's
    /// function-key characters.
    public var menuKeyEquivalent: String {
        func scalar(_ value: UInt32) -> String { String(Character(UnicodeScalar(value)!)) }
        switch key {
        case "left": return scalar(0xF702)
        case "right": return scalar(0xF703)
        case "up": return scalar(0xF700)
        case "down": return scalar(0xF701)
        case "return": return "\r"
        case "tab": return "\t"
        case "delete": return "\u{8}"
        case "escape": return "\u{1b}"
        case "space": return " "
        default:
            let isLetter = key.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            return modifiers.contains(.shift) && isLetter ? key.uppercased() : key
        }
    }

    public var keyDisplay: String {
        switch key {
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "return": return "↩"
        case "tab": return "⇥"
        case "delete": return "⌫"
        case "escape": return "⎋"
        case "space": return "Space"
        default: return key.uppercased()
        }
    }
}

extension Shortcut: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = Shortcut(string: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid shortcut \(raw)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}
