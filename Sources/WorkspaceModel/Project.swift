import Foundation
import Observation

public struct ProjectID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// A project the user made in the sidebar: a named group of tabs with a folder, where its new tabs
/// open. Projects belong to the workspace, so every window shows them; each tab says which one it
/// is in (`Tab.projectID`). The agents in a project's tabs are grouped under it too.
@MainActor
@Observable
public final class Project {
    public let id: ProjectID
    public var name: String
    public var directory: String
    /// Shown before the name; nil shows a folder.
    public var icon: PinIcon?
    /// Folded in the tab list and the Agents section alike.
    public var folded: Bool

    public init(id: ProjectID = ProjectID(), name: String, directory: String, icon: PinIcon? = nil, folded: Bool = false) {
        self.id = id
        self.name = name
        self.directory = directory
        self.icon = icon
        self.folded = folded
    }

    /// The name shown when the user leaves it blank: the folder's.
    public static func defaultName(for directory: String) -> String {
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "Project" : name
    }
}
