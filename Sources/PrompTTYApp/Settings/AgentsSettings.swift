import AgentHooks
import AppKit
import SwiftUI

/// Installs and removes PrompTTY's hooks in Claude Code's settings, only when asked (Settings ›
/// Agents, or the debug driver against its own folder).
@MainActor
enum ClaudeHooks {
    static var settingsFile: URL { AppPaths.claudeSettings }
    static var displayPath: String { (settingsFile.path as NSString).abbreviatingWithTildeInPath }

    static func status() -> ClaudeHookSettings.Status? {
        guard let helper = AppPaths.hookHelper else { return nil }
        return ClaudeHookSettings.status(helper: helper.path, in: settingsFile)
    }

    static func install() throws -> ClaudeHookSettings.Outcome {
        guard let helper = AppPaths.hookHelper else { throw ClaudeHookSettings.Failure.unreadable }
        return try ClaudeHookSettings.install(helper: helper.path, in: settingsFile)
    }

    static func remove() throws -> ClaudeHookSettings.Outcome {
        try ClaudeHookSettings.remove(in: settingsFile)
    }

    /// What installing changes, for the confirmation.
    static func installSummary(status: ClaudeHookSettings.Status?) -> String {
        let helper = AppPaths.hookHelper.map { $0.path } ?? "promptty-hook"
        let exists = FileManager.default.fileExists(atPath: settingsFile.path)
        var lines = [
            "PrompTTY will add a hook for each of these events to \(displayPath):",
            ClaudeHookSettings.events.map(\.rawValue).joined(separator: ", "),
            "",
            "Each runs: \(ClaudeHookSettings.command(helper: helper, event: .stop).replacingOccurrences(of: " Stop", with: " <event>"))",
            "",
        ]
        if status == .otherCopy { lines.append("The hooks of another copy of PrompTTY are replaced.") }
        lines.append(exists
            ? "Your other settings and hooks stay as they are. The file is first copied to settings.json.bak."
            : "The file does not exist yet; PrompTTY creates it.")
        lines.append("Claude Code sessions started afterwards use the hooks.")
        return lines.joined(separator: "\n")
    }

    static var removeSummary: String {
        "PrompTTY will take its own hooks (the commands running promptty-hook) out of \(displayPath) and leave everything else as it is. The file is first copied to settings.json.bak."
    }
}

/// Settings › Agents: Claude Code's hooks, which tell PrompTTY exactly what an agent does, and
/// how to set up Codex's.
struct AgentsSettingsSection: View {
    private enum Pending: Identifiable {
        case install, remove
        var id: Self { self }
    }

    @State private var status: ClaudeHookSettings.Status?
    @State private var pending: Pending?
    @State private var outcome: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Hooks") {
                    Text(statusText)
                        .foregroundStyle(status == .installed ? Color.primary : Color.secondary)
                }
                HStack(spacing: 8) {
                    Button("Install Claude Code Hooks…") { pending = .install }
                        .disabled(AppPaths.hookHelper == nil || status == .installed || status == .unreadable)
                    Button("Remove…") { pending = .remove }
                        .disabled(status == nil || status == .notInstalled || status == .unreadable)
                }
                if let outcome {
                    Text(outcome)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("With the hooks, Claude Code tells PrompTTY when it works, which tool it runs, when it needs your permission and when your turn comes, instead of PrompTTY guessing from the screen. They change \(ClaudeHooks.displayPath) only when you click Install or Remove; outside PrompTTY they do nothing.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(verbatim: "notify = [\"\(AppPaths.hookHelper?.path ?? "…/promptty-hook")\", \"codex-notify\"]")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("Codex")
            } footer: {
                Text("Add this line to ~/.codex/config.toml, above its first [section], for PrompTTY to know exactly when Codex finishes a turn.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { status = ClaudeHooks.status() }
        .alert(pending == .remove ? "Remove PrompTTY's Claude Code hooks?" : "Install Claude Code hooks?",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { action in
            Button(action == .remove ? "Remove" : "Install") { perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action == .remove ? ClaudeHooks.removeSummary : ClaudeHooks.installSummary(status: status))
        }
    }

    private var statusText: String {
        switch status {
        case .installed: "Installed"
        case .otherCopy: "Installed for another copy of PrompTTY"
        case .notInstalled: "Not installed"
        case .unreadable: "\(ClaudeHooks.displayPath) is not valid JSON"
        case nil: "Unavailable in this build"
        }
    }

    private func perform(_ action: Pending) {
        do {
            let result = action == .install ? try ClaudeHooks.install() : try ClaudeHooks.remove()
            switch (action, result) {
            case (.install, .changed): outcome = "Installed in \(ClaudeHooks.displayPath)."
            case (.remove, .changed): outcome = "Removed from \(ClaudeHooks.displayPath)."
            case (_, .unchanged): outcome = "Nothing to change."
            }
        } catch {
            outcome = "\(ClaudeHooks.displayPath) was not changed: \(error)"
        }
        status = ClaudeHooks.status()
    }
}
