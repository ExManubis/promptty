import Foundation

/// Where PrompTTY keeps its files. Debug builds launched with `PROMPTTY_DEBUG_DIR` use
/// `<dir>/support` instead, so automated runs never touch the real session or settings.
enum AppPaths {
    static let support: URL = {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["PROMPTTY_DEBUG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("support", isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PrompTTY", isDirectory: true)
    }()

    static var session: URL { support.appendingPathComponent("session.json") }
    static var folderHistory: URL { support.appendingPathComponent("folder-history.jsonl") }
}
