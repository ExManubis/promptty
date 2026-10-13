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

    /// A tab row's second line: "feature-x · Working · Bash · 20 s", "Needs permission · Bash ·
    /// 5 s · +1 agent", "Your turn · 2 min", "Waiting". The branch tells parallel agents apart; the
    /// tool shows while the agent works or asks to run it; `others` counts the tab's other agents.
    public static func status(branch: String?, display: PaneActivity.Display, tool: String?, since: Date?,
                              others: Int, now: Date) -> String {
        var parts: [String] = branch.map { [$0] } ?? []
        switch display {
        case .permission: parts.append("Needs permission")
        case .attention: parts.append("Your turn")
        case .working: parts.append("Working")
        default: parts.append("Waiting")
        }
        if let tool, display == .working || display == .permission { parts.append(tool) }
        if let since { parts.append(elapsed(now.timeIntervalSince(since))) }
        if others > 0 { parts.append(others == 1 ? "+1 agent" : "+\(others) agents") }
        return parts.joined(separator: " · ")
    }

    /// "1 min 20 s" is too busy beside an agent: seconds, then minutes, then hours and minutes.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    /// When `elapsed` next reads differently for a duration counted from `since`: the next second
    /// while it shows seconds, the next minute after that.
    public static func nextChange(since: Date, after now: Date) -> Date {
        let seconds = max(0, now.timeIntervalSince(since))
        let step: TimeInterval = seconds < 59 ? 1 : 60
        return since.addingTimeInterval((floor(seconds / step) + 1) * step)
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
