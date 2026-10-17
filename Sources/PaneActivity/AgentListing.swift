import Foundation

/// What a sidebar tab row shows of the agents in its tab, worked out once when something changes
/// rather than in a view's body.
public enum AgentListing {
    /// The agent a tab's row shows: the most urgent; ties go to the focused pane, then pane order.
    public static func mostUrgent<ID: Equatable>(_ agents: [(id: ID, display: PaneActivity.Display)], focused: ID?) -> ID? {
        guard let top = agents.map(\.display).max() else { return nil }
        let candidates = agents.filter { $0.display == top }
        return (candidates.first { $0.id == focused } ?? candidates[0]).id
    }

    /// An agent's line in the sidebar's Activity, as Rex's: "Working · Bash", "Needs permission ·
    /// Bash", "Your turn", "Done". How long ago it changed shows apart (`ago`).
    public static func activity(display: PaneActivity.Display, tool: String?) -> String {
        switch display {
        case .working: tool.map { "Working · \($0)" } ?? "Working"
        case .permission: tool.map { "Needs permission · \($0)" } ?? "Needs permission"
        case .attention: "Your turn"
        default: "Done"
        }
    }

    /// How long ago, as Rex's Activity reads it: "now", "5m", "12h", "3d".
    public static func ago(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "now" }
        if total < 3600 { return "\(total / 60)m" }
        if total < 86400 { return "\(total / 3600)h" }
        return "\(total / 86400)d"
    }

    /// How many other agents a tab has: "+1 agent", "+3 agents"; nil for none. Shown apart from
    /// the rest of the line, which truncates first.
    public static func others(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "+1 agent" : "+\(count) agents"
    }
}

/// Repositories by folder for the tab rows' agents, found off the main thread (`Repository.find`
/// reads the disk): which folders to look up now (new ones, and ones not looked at for a while:
/// an agent may switch branches), and folders no longer used forgotten.
public struct RepositoryCache {
    private var known: [String: (repository: Repository, at: Date)] = [:]
    /// Being looked up, and since when (a lookup that never answers is tried again).
    private var pending: [String: Date] = [:]
    private let refreshAfter: TimeInterval

    public init(refreshAfter: TimeInterval = 5) { self.refreshAfter = refreshAfter }

    /// The repository last found for a folder; nil before its first lookup has answered.
    public func repository(for folder: String) -> Repository? { known[folder]?.repository }

    /// The folders of `used` to look up now, counted as pending until `resolved`. Forgets the
    /// folders not in `used`.
    public mutating func due(_ used: Set<String>, at now: Date) -> [String] {
        known = known.filter { used.contains($0.key) }
        pending = pending.filter { used.contains($0.key) }
        var due: [String] = []
        for folder in used.sorted() {
            if let since = pending[folder], now.timeIntervalSince(since) < refreshAfter { continue }
            if let found = known[folder], now.timeIntervalSince(found.at) < refreshAfter { continue }
            pending[folder] = now
            due.append(folder)
        }
        return due
    }

    /// A lookup answered. Returns whether what the folder shows changed; an answer for a folder
    /// forgotten meanwhile is dropped.
    @discardableResult
    public mutating func resolved(_ folder: String, _ repository: Repository, at now: Date) -> Bool {
        guard pending.removeValue(forKey: folder) != nil else { return false }
        let changed = known[folder]?.repository != repository
        known[folder] = (repository, now)
        return changed
    }
}
