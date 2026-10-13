import Foundation

/// What a pinned tab comes back to on relaunch and reset: the folder it was pinned in and the
/// command that ran there then (`claude`, `npm run dev`), if any, and the icon the user gave it.
public struct TabPin: Codable, Equatable, Sendable {
    public var directory: String
    public var command: String?
    /// Shown on the tab's tile in place of its programs' logos; nil shows the logos.
    public var icon: PinIcon?

    public init(directory: String, command: String?, icon: PinIcon? = nil) {
        self.directory = directory
        self.command = Self.normalized(command)
        self.icon = icon
    }

    /// Blank is no command.
    static func normalized(_ command: String?) -> String? {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A pinned tab's own icon: an SF Symbol on a colored tile.
public struct PinIcon: Codable, Equatable, Sendable {
    public enum Color: String, Codable, CaseIterable, Sendable {
        case dark, red, orange, yellow, green, teal, blue, purple
    }

    /// An SF Symbol name.
    public var symbol: String
    public var color: Color

    public init(symbol: String, color: Color) {
        self.symbol = symbol
        self.color = color
    }

    private enum CodingKeys: String, CodingKey { case symbol, color }

    /// A color this version does not know (from a later one) is the default dark tile.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decode(String.self, forKey: .symbol)
        color = (try? container.decode(String.self, forKey: .color)).flatMap(Color.init(rawValue:)) ?? .dark
    }
}
