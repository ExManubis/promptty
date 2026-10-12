import Foundation

/// Where a zsh pane is between prompts.
public enum ShellPhase: Equatable, Sendable {
    /// A plain terminal: the shell has not reached its first prompt (or never will, e.g. not zsh).
    case starting
    /// At a prompt: the input bar is shown and takes the keys.
    case idle
    /// Something runs: no bar; keys go to the terminal.
    case running
}

/// How the last command ended. `code` is -1 when the shell did not report one.
public struct CommandExit: Equatable, Sendable {
    public var code: Int
    public var duration: TimeInterval

    public init(code: Int, duration: TimeInterval) {
        self.code = code
        self.duration = duration
    }
}

/// A pane's shell, as far as the input bar is concerned. PrompTTY's zsh integration reports the
/// directory (OSC 7) at every prompt; a report while the shell itself is in the foreground means
/// the prompt is ready.
public struct ShellPaneState: Equatable, Sendable {
    public private(set) var phase: ShellPhase = .starting
    /// The shell's pid: the foreground pid at its first prompt (precmd runs in the shell itself).
    public private(set) var shellPID: Int?
    public private(set) var lastExit: CommandExit?

    public init() {}

    /// The shell reported its directory while `foregroundPID` owned the terminal. Returns true when
    /// this made the pane idle.
    public mutating func pwdReported(foregroundPID: Int) -> Bool {
        guard foregroundPID > 0, phase != .idle else { return false }
        if shellPID == nil { shellPID = foregroundPID }
        guard foregroundPID == shellPID else { return false }
        phase = .idle
        return true
    }

    /// The user ran a command from the bar.
    public mutating func submitted() {
        guard phase == .idle else { return }
        phase = .running
    }

    /// Recorded for the header; the following prompt, not this, makes the pane idle again.
    public mutating func commandFinished(code: Int, durationNanoseconds: UInt64) {
        lastExit = CommandExit(code: code, duration: TimeInterval(durationNanoseconds) / 1_000_000_000)
    }

    /// The terminal's foreground process, polled while idle: anything but the shell (a job brought
    /// to the foreground, a program started by a hook) owns the keys.
    public mutating func foregroundChanged(to pid: Int) {
        guard phase == .idle, let shellPID, pid > 0, pid != shellPID else { return }
        phase = .running
    }
}
