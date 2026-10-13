import Foundation

/// The executables on a `PATH`, listed once per distinct `PATH` for all panes (restoring many
/// panes starts one scan, not one each), off the main thread.
public actor PathCommandCache {
    public static let shared = PathCommandCache()

    private struct Entry {
        var commands: Set<String>
        /// Each directory's modification date when listed: `brew install` changes one.
        var stamps: [Date?]
    }

    private static let capacity = 8
    private let scan: @Sendable ([String]) -> Set<String>
    private var cache: [[String]: Entry] = [:]
    /// Least recently used first.
    private var order: [[String]] = []
    private var scans: [[String]: Task<Set<String>, Never>] = [:]

    public init(scan: @escaping @Sendable ([String]) -> Set<String> = PathCommandCache.executables(in:)) {
        self.scan = scan
    }

    public func commands(on path: [String]) async -> Set<String> {
        if let entry = cache[path], entry.stamps == Self.stamps(of: path) {
            touch(path)
            return entry.commands
        }
        if let running = scans[path] { return await running.value }
        let scan = scan
        let stamps = Self.stamps(of: path)
        let task = Task.detached(priority: .utility) { scan(path) }
        scans[path] = task
        let found = await task.value
        scans[path] = nil
        cache[path] = Entry(commands: found, stamps: stamps)
        touch(path)
        while order.count > Self.capacity { cache[order.removeFirst()] = nil }
        return found
    }

    private func touch(_ path: [String]) {
        order.removeAll { $0 == path }
        order.append(path)
    }

    private static func stamps(of path: [String]) -> [Date?] {
        path.map { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
    }

    /// The names of the executable files in the directories of `path`.
    public static func executables(in path: [String]) -> Set<String> {
        var all = Set<String>()
        let fm = FileManager.default
        for dir in path {
            for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where fm.isExecutableFile(atPath: (dir as NSString).appendingPathComponent(entry)) {
                all.insert(entry)
            }
        }
        return all
    }
}
