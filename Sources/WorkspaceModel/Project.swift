import Foundation
import Observation

public struct ProjectID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// A project the user made in the sidebar's Agents section: a name the agents of its tabs are
/// grouped under. It is not a folder, and the tab list does not show it. Projects belong to the
/// workspace, so every window shows them; each tab says which one it is in (`Tab.projectID`).
@MainActor
@Observable
public final class Project {
    public let id: ProjectID
    public var name: String
    /// Shown before the name; nil shows a folder.
    public var icon: PinIcon?
    /// Folded in the Agents section; saved with the session.
    public var folded: Bool

    public init(id: ProjectID = ProjectID(), name: String, icon: PinIcon? = nil, folded: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.folded = folded
    }

    /// The name of a project the user left unnamed.
    public nonisolated static let untitled = "New Project"
}
