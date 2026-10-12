import Foundation

/// What a pinned tab comes back to on relaunch and reset: the folder it was pinned in and the
/// command that ran there then (`claude`, `npm run dev`), if any.
public struct TabPin: Codable, Equatable, Sendable {
    public var directory: String
    public var command: String?
    public init(directory: String, command: String?) {
        self.directory = directory
        self.command = Self.normalized(command)
    }

    /// Blank is no command.
    static func normalized(_ command: String?) -> String? {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
