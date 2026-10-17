import CommandEditing
import Foundation

/// Every pane's bar shares one record of which command ran in which folder, kept in a file of
/// JSON lines in PrompTTY's support folder.
@MainActor
final class FolderHistoryStore {
    static let shared = FolderHistoryStore(url: AppPaths.folderHistory)

    private let url: URL
    private var history = FolderHistory()
    /// The last ranking asked for, until the next command is added.
    private var cached: (directory: String, ranked: [String])?
    private let writes = DispatchQueue(label: "dev.promptty.folder-history", qos: .utility)
    /// Lines in the file, which only grows between rewrites.
    private var fileLines = 0
    /// Changes whenever a ranking may have changed.
    private(set) var revision = 0

    init(url: URL) {
        self.url = url
        // Read off the main thread; commands run meanwhile join what was read.
        writes.async { [url] in
            let data = (try? Data(contentsOf: url)) ?? Data()
            let loaded = FolderHistory.decode(data)
            let lines = data.split(separator: 0x0A).count
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let added = self.history.entries
                    self.history = FolderHistory(entries: loaded.entries + added)
                    self.fileLines = lines + added.count
                    self.cached = nil
                    self.revision += 1
                }
            }
        }
    }

    func ranked(for directory: String) -> [String] {
        if let cached, cached.directory == directory { return cached.ranked }
        let ranked = history.ranked(for: directory)
        cached = (directory, ranked)
        return ranked
    }

    /// The folders commands ran in, most used and most recent first (⌘J).
    func frecentFolders() -> [FolderHistory.Visited] { history.frecentFolders(now: Date()) }

    /// Records a command for this session's suggestions, and on disk only when the shell keeps a
    /// history file itself: a shell with `HISTFILE` unset is not recorded either.
    func add(_ command: String, in directory: String, persist: Bool) {
        guard let entry = history.add(command: command, directory: directory, date: Date()) else { return }
        cached = nil
        revision += 1
        guard persist else { return }
        let url = url
        // The file keeps only the newest entries: rewritten whole once it has grown well past them.
        fileLines += 1
        var rewrite: [FolderHistory.Entry]?
        if fileLines > FolderHistory.limit + 500 {
            rewrite = history.entries
            fileLines = history.entries.count
        }
        writes.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let rewrite {
                let all = rewrite.reduce(into: Data()) { $0 += FolderHistory.line(for: $1) }
                try? all.write(to: url, options: .atomic)
            } else if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: FolderHistory.line(for: entry))
                try? handle.close()
            } else {
                fm.createFile(atPath: url.path, contents: FolderHistory.line(for: entry))
            }
            // Private, as zsh keeps its history.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Forgets every recorded command, in memory and on disk.
    func clear() {
        history = FolderHistory()
        cached = nil
        fileLines = 0
        let url = url
        writes.async { try? FileManager.default.removeItem(at: url) }
    }
}
