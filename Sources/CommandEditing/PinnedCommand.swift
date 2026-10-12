import Foundation

/// The command a tab is pinned with: what runs in it at the moment of pinning.
public enum PinnedCommand {
    /// The command as typed in the bar (`npm run dev`, not the `node …/npm-cli.js` it became),
    /// else the running program's arguments quoted for zsh. Nil when only the shell runs.
    public static func capture(running: Bool, lastCommand: String?, arguments: [String]?) -> String? {
        guard running else { return nil }
        if let typed = lastCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty { return typed }
        guard let arguments, !arguments.isEmpty else { return nil }
        return arguments.map { ShellQuoting.escape($0, keepLeadingTilde: false) }.joined(separator: " ")
    }
}
