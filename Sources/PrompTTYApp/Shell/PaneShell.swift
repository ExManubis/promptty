import AppKit
import CommandEditing
import SwiftUI
import Darwin
import GhosttyBridge
import Observation
import WorkspaceModel

/// Where the zsh integration lives and what a pane's shell is. Set up once at launch.
@MainActor
enum ShellIntegration {
    /// Nil when the user's login shell is not zsh, or the integration could not be installed:
    /// panes are then plain terminals.
    private(set) static var zshDirectory: URL?

    static var stateDirectory: URL { AppPaths.support.appendingPathComponent("shell/state", isDirectory: true) }

    static func install() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PROMPTTY_DEBUG_NO_INTEGRATION"] == "1" { return }
        #endif
        guard ZshIntegration.isZsh(shellPath: loginShell) else { return }
        do {
            zshDirectory = try ZshIntegration.install(in: AppPaths.support.appendingPathComponent("shell/zsh", isDirectory: true))
            // Files of panes from earlier runs (closed by quitting) are stale.
            try? FileManager.default.removeItem(at: stateDirectory)
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        } catch {
            zshDirectory = nil
        }
    }

    /// The shell libghostty starts: the user's login shell.
    static var loginShell: String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "" }
        return String(cString: shell)
    }

    static func stateFile(for pane: PaneID) -> URL {
        stateDirectory.appendingPathComponent(pane.rawValue.uuidString)
    }

    /// The environment for a new pane's shell; empty without the integration.
    static func environment(for pane: PaneID) -> [String: String] {
        guard let zshDirectory else { return [:] }
        return ZshIntegration.environment(
            integrationDirectory: zshDirectory,
            stateFile: stateFile(for: pane),
            userZDOTDIR: ProcessInfo.processInfo.environment["ZDOTDIR"]
        )
    }
}

/// How the input bar is shown.
enum BarPresentation: Equatable {
    /// Not part of the pane (a plain terminal, or a command that has been running for a while).
    case hidden
    /// At a prompt: in the layout, taking keys.
    case active
    /// A command just started: still in the layout so a quick command never makes it blink.
    case inactive
}

/// Syntax colors for the editor, from the terminal theme's ANSI palette.
struct EditorColors {
    var text: NSColor = .textColor
    var command: NSColor = .systemGreen
    var unknownCommand: NSColor = .systemRed
    var flag: NSColor = .systemTeal
    var string: NSColor = .systemYellow
    var variable: NSColor = .systemBlue
    var op: NSColor = .systemPurple
    var comment: NSColor = .secondaryLabelColor
    var ghost: NSColor = .tertiaryLabelColor
    /// The input bar's folder and branch buttons: the theme's cyan and magenta, as Starship shows
    /// them.
    var folder: NSColor = .systemCyan
    var branch: NSColor = .systemPurple
}

/// The editor font (the terminal's family and size, so typed commands look like terminal text)
/// and colors (the terminal theme's).
@MainActor
enum EditorStyle {
    static var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static var colors = EditorColors()
    /// The caret's color when the cursor color is set (Settings › Appearance); nil for the text's.
    static var cursor: NSColor?

    /// `palette` is the theme's 16 ANSI colors.
    static func update(foreground: (red: UInt8, green: UInt8, blue: UInt8)?, palette: [(red: UInt8, green: UInt8, blue: UInt8)]?) {
        func color(_ c: (red: UInt8, green: UInt8, blue: UInt8)) -> NSColor {
            NSColor(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255, alpha: 1)
        }
        var colors = EditorColors()
        if let foreground { colors.text = color(foreground) }
        if let palette, palette.count >= 16 {
            colors.unknownCommand = color(palette[1])
            colors.command = color(palette[2])
            colors.string = color(palette[3])
            colors.variable = color(palette[4])
            colors.op = color(palette[5])
            colors.flag = color(palette[6])
            colors.comment = color(palette[8])
            colors.ghost = color(palette[8])
            colors.folder = color(palette[6])
            colors.branch = color(palette[5])
        }
        self.colors = colors
    }

    static func update(family: String, size: Double) {
        let size = CGFloat(size)
        font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont(name: family, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// One pane's shell as the input bar sees it: whether it is at a prompt, what the header shows,
/// and what the shell told us about itself (history, commands, PATH).
@MainActor
@Observable
final class PaneShell {
    let pane: PaneID
    /// Whether this pane's shell loads PrompTTY's integration (zsh only).
    let integrated: Bool
    private(set) var state = ShellPaneState()
    var phase: ShellPhase { state.phase }
    private(set) var directory: String
    private(set) var git: GitStatus?
    private(set) var stateFile: ShellStateFile?
    /// The commands the bar offers: this pane's own on top of the history file's, which the panes
    /// using the same HISTFILE share (until the shell reports which that is, a file of its own).
    @ObservationIgnored private(set) var history = CommandHistory()
    private(set) var bar: BarPresentation = .hidden
    /// The last command run from the bar or a picker, for a notification when it finishes unseen.
    @ObservationIgnored private(set) var lastCommand: String?
    /// The editor's height for its current text (one to eight lines).
    private(set) var editorHeight: CGFloat = 18
    /// The header's folder and branch colors, from the theme (observed, so they follow it).
    private(set) var folderColor: NSColor = EditorStyle.colors.folder
    private(set) var branchColor: NSColor = EditorStyle.colors.branch

    /// The bar's editor. Long-lived like the terminal: hosts move it, never recreate it.
    @ObservationIgnored private(set) lazy var editor: CommandEditorView = makeEditor()

    /// Called when the pane reaches a prompt (`.idle`) or leaves it.
    @ObservationIgnored var onPhaseChange: ((ShellPhase) -> Void)?
    @ObservationIgnored weak var surface: TerminalSurfaceView?

    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var stateFileDate: Date?
    /// ⏎ was pressed while a quick command still ran: the bar's text runs at the next prompt.
    @ObservationIgnored private var queuedSubmit = false
    /// The running command came from a picker (`cd`, `git switch`): the bar's draft is the
    /// user's, not input for it.
    @ObservationIgnored private var keepingDraft = false
    /// A program other than the shell in the foreground during that command, and for how many polls.
    @ObservationIgnored private var hookForeground: (pid: Int, polls: Int) = (0, 0)
    /// How many polls that program may keep the terminal before it gets the keys.
    @ObservationIgnored private var handOverPolls = 4
    @ObservationIgnored private var gitGeneration = 0

    /// Run from the bar at the first prompt (a pinned tab's command).
    @ObservationIgnored private var startupCommand: String?

    init(pane: PaneID, directory: String, integrated: Bool, startupCommand: String? = nil) {
        self.pane = pane
        self.directory = directory
        self.integrated = integrated
        self.startupCommand = startupCommand
        editorHeight = CommandTextView.lineHeight(for: EditorStyle.font)
    }

    // MARK: Events

    /// A directory report from the terminal. Returns true when it was the integration's ready
    /// signal, which is not a real directory and must not reach the pane's model.
    func directoryReported(_ path: String) -> Bool {
        guard integrated, let dir = ZshIntegration.readyDirectory(fromReportedPath: path) else {
            moveTo(path)
            return false
        }
        moveTo(dir)
        guard let pid = surface?.foregroundPID, state.promptReady(foregroundPID: pid) else { return true }
        reloadStateFileIfChanged()
        reloadHistoryIfChanged()
        branchCache = [:]
        branchEpoch += 1
        refreshGit()
        phaseChanged()
        if startupCommand != nil {
            // After the prompt is announced, so the bar has the keys, like a typed command. Kept
            // for the next prompt if this one is gone by then.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.bar == .active, self.state.phase == .idle, let command = self.startupCommand else { return }
                    self.startupCommand = nil
                    self.run(command, recordingHistory: false)
                }
            }
        }
        return true
    }

    private func moveTo(_ dir: String) {
        guard dir != directory else { return }
        directory = dir
        refreshGit()
    }

    func commandFinished(code: Int16, durationNs: UInt64) {
        state.commandFinished(code: Int(code), durationNanoseconds: durationNs)
    }

    // MARK: The bar

    private func makeEditor() -> CommandEditorView {
        let view = CommandEditorView()
        let text = view.textView
        text.font = EditorStyle.font
        text.styleChanged()
        text.terminal = surface
        text.onSubmit = { [weak self] in self?.submit($0) }
        text.history = { [weak self] in self?.history.merged ?? MergedHistory(newestFirst: []) }
        text.suggestionGeneration = { [weak self] in
            guard let self else { return 0 }
            var hasher = Hasher()
            hasher.combine(self.history.version)
            hasher.combine(self.directory)
            hasher.combine(FolderHistoryStore.shared.revision)
            return hasher.finalize()
        }
        text.folderHistory = { [weak self] in self.map { FolderHistoryStore.shared.ranked(for: $0.directory) } ?? [] }
        text.isKnownCommand = { [weak self] in self?.isKnownCommand($0) ?? true }
        text.completionDirectory = { [weak self] in self?.directory }
        text.completionNames = { [weak self] in
            self.map { CompletionSnapshot(commands: $0.completionCommandNames, exports: $0.stateFile?.exports ?? []) }
        }
        text.listEntries = { path in
            await Task.detached(priority: .userInitiated) { DirectoryListing.entries(inDirectory: path) }.value
        }
        text.loadBranches = { [weak self] directory in await self?.localBranches(in: directory) ?? [] }
        text.onShellControl = { [weak self] in self?.surface?.sendControl($0) }
        text.onTextChange = { [weak self] in self?.editorTextChanged() }
        return view
    }

    func styleChanged() {
        editor.textView.font = EditorStyle.font
        editor.textView.styleChanged()
        editorTextChanged()
        folderColor = EditorStyle.colors.folder
        branchColor = EditorStyle.colors.branch
    }

    /// Command names the shell runs without a path: its aliases, functions, builtins, reserved
    /// words and the executables on its PATH. Empty until the PATH has been listed.
    @ObservationIgnored private var knownCommands: Set<String> = []

    /// Unknown until the shell has reported its names: nothing shows as unknown before then.
    func isKnownCommand(_ name: String) -> Bool {
        if name.contains("/") {
            let path = (name as NSString).expandingTildeInPath
            let full = path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
            return FileManager.default.isExecutableFile(atPath: full)
        }
        return knownCommands.isEmpty || knownCommands.contains(name)
    }

    /// `knownCommands` and the shell's own names together, merged once (thousands of names) and
    /// again only when either changes.
    @ObservationIgnored private var mergedCommandNames: Set<String>?

    private var completionCommandNames: Set<String> {
        if let merged = mergedCommandNames { return merged }
        let merged = knownCommands.union(stateFile?.commandNames ?? [])
        mergedCommandNames = merged
        return merged
    }

    /// The local branches by directory, kept across completion lists and dropped at every prompt:
    /// a checkout or a new branch happens between prompts.
    @ObservationIgnored private var branchCache: [String: [String]] = [:]
    @ObservationIgnored private var branchEpoch = 0
    @ObservationIgnored private var branchLookups: [String: Task<[String]?, Never>] = [:]

    /// The local branches of the repository at `directory`; empty when it is none. Never blocks the
    /// main thread.
    func localBranches(in directory: String) async -> [String] {
        if let cached = branchCache[directory] { return cached }
        if let running = branchLookups[directory] { return await running.value ?? [] }
        let epoch = branchEpoch
        let path = stateFile?.path ?? []
        let lookup = Task.detached(priority: .userInitiated) { () -> [String]? in
            let git = Self.executable("git", in: path) ?? "/usr/bin/git"
            return Self.run(git, ["-C", directory, "for-each-ref", "--format=%(refname:short)", "refs/heads"], timeout: 1)
                .map { $0.split(separator: "\n").map(String.init) }
        }
        branchLookups[directory] = lookup
        let branches = await lookup.value
        branchLookups[directory] = nil
        // A failure or timeout is not remembered: the next Tab asks again.
        if let branches, epoch == branchEpoch { branchCache[directory] = branches }
        return branches ?? []
    }

    private func listCommands() {
        guard let stateFile else { return }
        let names = stateFile.commandNames
        let path = stateFile.path
        Task.detached(priority: .utility) {
            var all = names
            let fm = FileManager.default
            for dir in path {
                for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where fm.isExecutableFile(atPath: (dir as NSString).appendingPathComponent(entry)) {
                    all.insert(entry)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.knownCommands = all
                self.mergedCommandNames = nil
                self.editor.textView.recolor()
            }
        }
    }

    private func editorTextChanged() {
        editorHeight = editor.textView.height()
    }

    /// ⏎ in the bar. At a prompt the command runs; while a quick command still runs (the bar is
    /// still shown) it runs at the next prompt, so typing ahead of a fast command loses nothing.
    private func submit(_ command: String) {
        switch bar {
        case .active: run(command)
        case .inactive: queuedSubmit = true
        case .hidden: break
        }
    }

    /// zsh gets the command as a paste (one line edit, however many lines) followed by Return.
    /// A pinned tab's command, run again at each launch, is not added to the suggestions again.
    private func run(_ command: String, recordingHistory: Bool = true) {
        guard state.phase == .idle, let surface else { return }
        if !command.isEmpty {
            surface.sendText(command)
            if recordingHistory {
                history.add(command)
                FolderHistoryStore.shared.add(command, in: directory, persist: stateFile?.historyFile != nil)
            }
            lastCommand = command
        }
        surface.sendReturn()
        editor.textView.commandRan()
        state.submitted()
        phaseChanged()
    }

    /// After a picker closes from its own keys or a click on a row: the keys go back to the bar.
    /// (Closed by a click elsewhere, the keys stay where that click put them.)
    func returnKeysToBar() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let editor = self?.editor.textView else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }

    /// The folder picker's choice. The shell's own hooks run during a `cd`; a program that keeps
    /// the terminal for a second is one of them asking something.
    func changeDirectory(to path: String) {
        runKeepingDraft(ShellQuoting.cdCommand(to: path, home: NSHomeDirectory()), handOverAfter: 1)
    }

    /// The branch picker's choice. git itself has the terminal while it checks files out, which
    /// can take a while in a large repository.
    func switchBranch(_ row: BranchList.Row) {
        runKeepingDraft(BranchList.command(for: row), handOverAfter: 10)
    }

    /// A picker's command runs like a typed one (in the scrollback and the history) and leaves
    /// whatever is half-typed in the bar where it is. A program other than the shell that keeps
    /// the terminal for `handOverAfter` seconds gets it, and the keys.
    private func runKeepingDraft(_ command: String, handOverAfter seconds: TimeInterval) {
        guard bar == .active, state.phase == .idle, let surface else { return }
        surface.sendText(command)
        history.add(command)
        lastCommand = command
        surface.sendReturn()
        keepingDraft = true
        handOverPolls = max(1, Int(seconds / 0.25))
        state.submitted()
        phaseChanged()
    }

    /// The repository's branches for the branch picker; nil when git cannot list them.
    func listBranches() async -> BranchListing? {
        let dir = directory
        let git = Self.executable("git", in: stateFile?.path ?? []) ?? "/usr/bin/git"
        return await Task.detached(priority: .userInitiated) {
            Self.run(git, ["-C", dir, "for-each-ref", "--sort=-committerdate", "--format=%(refname)%09%(worktreepath)", "refs/heads", "refs/remotes"], timeout: 2)
                .map(BranchListing.init(forEachRef:))
        }.value
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        try? FileManager.default.removeItem(at: ShellIntegration.stateFile(for: pane))
    }

    private func phaseChanged() {
        poll?.invalidate()
        poll = nil
        switch state.phase {
        case .idle:
            bar = .active
            keepingDraft = false
            if queuedSubmit {
                queuedSubmit = false
                // After this change is announced, so focus has settled on the bar.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.bar == .active else { return }
                        self.run(self.editor.textView.string)
                    }
                }
            }
        case .starting:
            bar = .hidden
        case .running where bar == .active:
            // Started from the bar: it stays put for a moment, so a quick command (most of them)
            // finishes without the bar or the terminal moving.
            bar = .inactive
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.state.phase == .running, self.bar == .inactive else { return }
                    // A picker's command can take longer (a `cd` runs the shell's hooks, direnv
                    // or a prompt's git status; `git switch` checks files out); the bar keeps the
                    // draft and a queued ⏎ unless a program takes the terminal.
                    if self.keepingDraft {
                        self.hookForeground = (0, 0)
                        self.poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                            MainActor.assumeIsolated { self?.checkForegroundWhileKeepingDraft() }
                        }
                        return
                    }
                    let fade: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.12)
                    // Still running: from here keys belong to the program, and so does what was
                    // typed in the meantime (an answer to a prompt, a password for sudo).
                    let typed = self.editor.textView.string
                    if !self.keepingDraft, !typed.isEmpty || self.queuedSubmit, let surface = self.surface {
                        if !typed.isEmpty { surface.sendText(typed) }
                        if self.queuedSubmit { surface.sendReturn() }
                        self.editor.textView.commandRan()
                    }
                    self.queuedSubmit = false
                    withAnimation(fade) { self.bar = .hidden }
                    self.onPhaseChange?(self.state.phase)
                }
            }
        case .running:
            queuedSubmit = false
            bar = .hidden
        }
        onPhaseChange?(state.phase)
    }

    /// While a picker's command runs: a program other than the shell that keeps the foreground
    /// past the command's allowance (a hook that asks something, not one that runs `git` for a
    /// moment) gets the terminal and the keys, the draft staying in the hidden bar.
    private func checkForegroundWhileKeepingDraft() {
        guard state.phase == .running, bar == .inactive, keepingDraft else {
            poll?.invalidate()
            poll = nil
            return
        }
        guard let pid = surface?.foregroundPID, pid > 0, let shellPID = state.shellPID, pid != shellPID else {
            hookForeground = (0, 0)
            return
        }
        hookForeground = hookForeground.pid == pid ? (pid, hookForeground.polls + 1) : (pid, 1)
        guard hookForeground.polls >= handOverPolls else { return }
        hookForeground = (0, 0)
        poll?.invalidate()
        poll = nil
        queuedSubmit = false
        bar = .hidden
        onPhaseChange?(state.phase)
    }

    /// Something other than the shell can take the terminal without a command from the bar (`fg`,
    /// a program started by a hook): the activity tracker's shared timer calls this for idle shells.
    func checkForeground() {
        guard state.phase == .idle, let pid = surface?.foregroundPID else { return }
        let before = state.phase
        state.foregroundChanged(to: pid)
        if state.phase != before { phaseChanged() }
    }

    // MARK: What the shell told us

    /// The integration rewrites the state file at every prompt (PATH and aliases change: direnv,
    /// nvm, a new alias); reread it when it changed.
    private func reloadStateFileIfChanged() {
        let url = ShellIntegration.stateFile(for: pane)
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let date, date != stateFileDate, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        stateFileDate = date
        let parsed = ShellStateFile.parse(text)
        guard parsed != stateFile else { return }
        let namesChanged = parsed.path != stateFile?.path || parsed.commandNames != stateFile?.commandNames
        stateFile = parsed
        if namesChanged { mergedCommandNames = nil }
        if namesChanged { listCommands() }
    }

    private func reloadHistoryIfChanged() {
        guard let path = stateFile?.historyFile else { return }
        let store = HistoryStore.shared(forPath: path)
        history.use(store)
        store.reloadIfChanged()
    }

    private func refreshGit() {
        gitGeneration += 1
        let generation = gitGeneration
        let dir = directory
        let git = Self.executable("git", in: stateFile?.path ?? []) ?? "/usr/bin/git"
        Task.detached(priority: .utility) {
            let status = Self.run(git, ["-C", dir, "--no-optional-locks", "status", "--porcelain=v2", "--branch"], timeout: 1)
                .flatMap { GitStatus.parse(porcelainV2: $0) }
            await MainActor.run { [weak self] in
                guard let self, generation == self.gitGeneration else { return }
                self.git = status
            }
        }
    }

    nonisolated static func executable(_ name: String, in path: [String]) -> String? {
        path.map { ($0 as NSString).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a program and returns its standard output, or nil on failure or after `timeout` seconds.
    nonisolated static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        // Read as output arrives: a full pipe would otherwise stall the program until the timeout.
        let collected = OutputBuffer()
        out.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        guard done.wait(timeout: .now() + timeout) == .success else {
            p.terminate()
            out.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        out.fileHandleForReading.readabilityHandler = nil
        collected.append(out.fileHandleForReading.readDataToEndOfFile())
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: collected.data, as: UTF8.self)
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
