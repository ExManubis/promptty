import AgentHooks
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

    /// A debug build driven by `script/drive` (launched with `PROMPTTY_DEBUG_DIR`).
    static let isDriven: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PROMPTTY_DEBUG_DIR"].map { !$0.isEmpty } ?? false
        #else
        return false
        #endif
    }()

    static var session: URL { support.appendingPathComponent("session.json") }
    /// What tabs showed when the app quit (`ScrollbackArchive`).
    static var scrollback: URL { support.appendingPathComponent("scrollback", isDirectory: true) }
    static var folderHistory: URL { support.appendingPathComponent("folder-history.jsonl") }

    /// Where agents' hooks reach the app (`PROMPTTY_SOCKET` in every pane): `hooks.sock` in the
    /// data folder, so a debug run's app has its own; a short path in the temporary folder when
    /// the data folder's is too long for a socket (see `HookSocket`).
    static let hookSocket = HookSocket.path(dataFolder: support.path, temporaryDirectory: NSTemporaryDirectory())

    /// Claude Code's user settings, where Settings › Agents installs the hooks. A debug run uses
    /// `<dir>/home/.claude/settings.json`, never the real one.
    static let claudeSettings: URL = {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["PROMPTTY_DEBUG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("home/.claude/settings.json")
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }()

    /// The folder holding the user's ssh config (`~/.ssh`); a debug run uses `<dir>/home/.ssh`.
    static let sshDirectory: URL = {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["PROMPTTY_DEBUG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("home/.ssh", isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }()

    /// The hook helper inside the app bundle; nil when the bundle has none.
    static var hookHelper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/promptty-hook")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
