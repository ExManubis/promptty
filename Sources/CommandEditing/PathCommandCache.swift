import Foundation

/// The executables on a `PATH`, listed once per distinct `PATH` for all panes (restoring many
/// panes starts one scan, not one each), off the main thread.
public actor PathCommandCache {
    public static let shared = PathCommandCache()

    private let scan: @Sendable ([String]) -> Set<String>
    private var cache: [[String]: Set<String>] = [:]
    private var scans: [[String]: Task<Set<String>, Never>] = [:]

    public init(scan: @escaping @Sendable ([String]) -> Set<String> = PathCommandCache.executables(in:)) {
        self.scan = scan
    }

    public func commands(on path: [String]) async -> Set<String> {
        if let cached = cache[path] { return cached }
        if let running = scans[path] { return await running.value }
        let scan = scan
        let task = Task.detached(priority: .utility) { scan(path) }
        scans[path] = task
        let found = await task.value
        scans[path] = nil
        cache[path] = found
        return found
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
