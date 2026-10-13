import Foundation

/// What the sidebar's Agents section shows of an agent pane, worked out once when something
/// changes rather than in a view's body.
public enum AgentListing {
    /// The row's title: the pane's own title, or the program's name when the pane has none (or
    /// only its folder as a title).
    public static func title(paneTitle: String, workingDirectory: String, program: Program) -> String {
        let own = paneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty || own == workingDirectory ? program.name : own
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

/// Repositories by folder for the Agents section, found off the main thread (`Repository.find`
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
