import Foundation
import Observation

public struct PaneID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// One terminal inside a tab.
@MainActor
@Observable
public final class Pane {
    public let id: PaneID
    /// Title reported by the terminal (OSC 0/2 via Ghostty `set_title`).
    public var title: String
    /// Last working directory reported via OSC 7 (Ghostty `pwd`), or the launch directory.
    public var workingDirectory: String
    /// Run at the shell's first prompt (a pinned tab's command), then cleared.
    @ObservationIgnored public var startupCommand: String?

    public init(id: PaneID = PaneID(), title: String = "", workingDirectory: String, startupCommand: String? = nil) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.startupCommand = startupCommand
    }
}
