import CommandEditing
import Foundation

/// Every pane's bar shares one record of which command ran in which folder, kept in a file of
/// JSON lines in PrompTTY's support folder.
@MainActor
final class FolderHistoryStore {
    static let shared = FolderHistoryStore(url: AppPaths.folderHistory)

    private let url: URL
    private var history: FolderHistory
    /// The last ranking asked for, until the next command is added.
    private var cached: (directory: String, ranked: [String])?
    private let writes = DispatchQueue(label: "dev.promptty.folder-history", qos: .utility)
    /// Lines in the file, which only grows between rewrites.
    private var fileLines: Int

    init(url: URL) {
        self.url = url
        let data = (try? Data(contentsOf: url)) ?? Data()
        history = FolderHistory.decode(data)
        fileLines = data.split(separator: 0x0A).count
    }

    func ranked(for directory: String) -> [String] {
        if let cached, cached.directory == directory { return cached.ranked }
        let ranked = history.ranked(for: directory)
        cached = (directory, ranked)
        return ranked
    }

    func add(_ command: String, in directory: String) {
        guard let entry = history.add(command: command, directory: directory, date: Date()) else { return }
        cached = nil
        let url = url
        let line = FolderHistory.line(for: entry)
        // The file keeps only the newest entries: rewritten whole once it has grown well past them.
        fileLines += 1
        var all: Data?
        if fileLines > FolderHistory.limit + 500 {
            all = history.entries.reduce(into: Data()) { $0 += FolderHistory.line(for: $1) }
            fileLines = history.entries.count
        }
        writes.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let all {
                try? all.write(to: url, options: .atomic)
            } else if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                try? line.write(to: url)
            }
        }
    }
}
