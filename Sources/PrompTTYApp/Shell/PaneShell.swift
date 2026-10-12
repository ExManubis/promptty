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
}

/// The editor font (the terminal's family and size, so typed commands look like terminal text)
/// and colors (the terminal theme's).
@MainActor
enum EditorStyle {
    static var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static var colors = EditorColors()

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
    private(set) var history = CommandHistory(fileEntries: [])
    private(set) var bar: BarPresentation = .hidden
    /// The editor's height for its current text (one to eight lines).
    private(set) var editorHeight: CGFloat = 18

    /// The bar's editor. Long-lived like the terminal: hosts move it, never recreate it.
    @ObservationIgnored private(set) lazy var editor: CommandEditorView = makeEditor()

    /// Called when the pane reaches a prompt (`.idle`) or leaves it.
    @ObservationIgnored var onPhaseChange: ((ShellPhase) -> Void)?
    @ObservationIgnored weak var surface: TerminalSurfaceView?

    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var historyDate: Date?
    @ObservationIgnored private var gitGeneration = 0

    init(pane: PaneID, directory: String, integrated: Bool) {
        self.pane = pane
        self.directory = directory
        self.integrated = integrated
        editorHeight = CommandTextView.lineHeight(for: EditorStyle.font)
    }

    // MARK: Events

    /// The shell reported its directory (our precmd does at every prompt).
    func pwdReported(_ dir: String) {
        let moved = dir != directory
        directory = dir
        if moved { refreshGit() }
        guard integrated, let pid = surface?.foregroundPID else { return }
        let wasStarting = state.phase == .starting
        if state.pwdReported(foregroundPID: pid) {
            if wasStarting { loadStateFile() }
            reloadHistoryIfChanged()
            if !moved { refreshGit() }
            phaseChanged()
        }
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
        text.onSubmit = { [weak self] in self?.run($0) }
        text.history = { [weak self] in self?.history.newestFirst ?? [] }
        text.isKnownCommand = { [weak self] in self?.isKnownCommand($0) ?? true }
        text.onShellInput = { [weak self] in self?.surface?.sendInput($0) }
        text.onTextChange = { [weak self] in self?.editorTextChanged() }
        return view
    }

    func styleChanged() {
        editor.textView.font = EditorStyle.font
        editor.textView.styleChanged()
        editorTextChanged()
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
                self.editor.textView.recolor()
            }
        }
    }

    private func editorTextChanged() {
        editorHeight = editor.textView.height()
    }

    /// Runs `command` from the bar: zsh gets it as a paste (so it is one line edit, however many
    /// lines) followed by Return.
    private func run(_ command: String) {
        guard state.phase == .idle, let surface else { return }
        if !command.isEmpty {
            surface.sendText(command)
            history.add(command)
        }
        surface.sendInput("\r")
        editor.textView.commandRan()
        state.submitted()
        phaseChanged()
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
        case .starting:
            bar = .hidden
        case .running where bar == .active:
            // Started from the bar: it stays put for a moment, so a quick command (most of them)
            // finishes without the bar or the terminal moving.
            bar = .inactive
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.state.phase == .running, self.bar == .inactive else { return }
                    let fade: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.12)
                    withAnimation(fade) { self.bar = .hidden }
                }
            }
        case .running:
            bar = .hidden
        }
        if state.phase == .idle {
            // Something other than the shell can take the terminal without a command from the bar
            // (`fg`, a program started by a hook): watch the foreground process while idle.
            poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkForeground() }
            }
        }
        onPhaseChange?(state.phase)
    }

    private func checkForeground() {
        guard let pid = surface?.foregroundPID else { return }
        let before = state.phase
        state.foregroundChanged(to: pid)
        if state.phase != before { phaseChanged() }
    }

    // MARK: What the shell told us

    private func loadStateFile() {
        let url = ShellIntegration.stateFile(for: pane)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        stateFile = ShellStateFile.parse(text)
        listCommands()
    }

    private func reloadHistoryIfChanged() {
        guard let path = stateFile?.historyFile else { return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let date, date != historyDate else { return }
        historyDate = date
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return }
            let entries = ZshHistory.parse(data)
            await MainActor.run { [weak self] in self?.history.replaceFileEntries(entries) }
        }
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
