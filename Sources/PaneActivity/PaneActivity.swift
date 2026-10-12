import Foundation

/// What a pane is doing, as far as its tab and header show it: whether something runs in it, and
/// what happened there that the user has not seen yet.
public struct PaneActivity: Equatable, Sendable {
    /// What the indicator shows, least to most urgent; a tab shows its most urgent pane.
    public enum Display: Equatable, Comparable, Sendable {
        case idle
        case running
        /// An agent at work: its screen keeps changing.
        case working
        case finished
        case failed(Int)
        case attention

        private var rank: Int {
            switch self {
            case .idle: 0
            case .running: 1
            case .working: 2
            case .finished: 3
            case .failed: 4
            case .attention: 5
            }
        }

        public static func < (a: Display, b: Display) -> Bool { a.rank < b.rank }
    }

    /// The pane's foreground process.
    public enum Foreground: Equatable, Sendable {
        case shell
        /// A program PrompTTY does not recognise.
        case command
        case program(Program)
    }

    private enum Unseen: Equatable, Sendable {
        case finished
        case failed(Int)
        case attention
    }

    /// The recognised program that runs, if any.
    public private(set) var program: Program?
    public private(set) var isRunning = false
    private var startedAt: Date?
    private var unseen: Unseen?
    /// The shell says how each command ends (OSC 133;D at the prompt): that report, not the shell
    /// coming back to the front, ends a command.
    private var reportsExits = false
    /// While running: when the shell was first seen back in front, and how often since.
    private var shellSince: Date?
    private var shellObservations = 0

    /// An agent in front works while its screen changes, and waits once it has been still.
    public private(set) var isWorking = false
    /// When the agent started working, or waiting.
    public private(set) var agentSince: Date?
    private var lastScreenChange: Date?
    private var workStarted: Date?
    /// A change not yet confirmed by a second one (a lone change is a clock or a redraw).
    private var firstChange: Date?
    /// The user saw the pane at some tick since its screen last changed.
    private var seenSinceChange = false
    /// An agent is waiting once its screen has been still this long.
    static let agentQuiet: TimeInterval = 3

    /// Commands that take at least this long notify when they finish unseen.
    public static let notifyAfter: TimeInterval = 10
    /// With exit reports: how long the shell may be in front without one before the command is
    /// taken to have ended anyway.
    static let reportGrace: TimeInterval = 3

    public init() {}

    public var display: Display {
        switch unseen {
        case .attention: .attention
        case .failed(let code): .failed(code)
        case .finished: .finished
        case nil: isWorking ? .working : isRunning ? .running : .idle
        }
    }

    /// What views show of a pane; the per-second bookkeeping is left out, so views redraw only
    /// when this changes.
    public struct Visible: Equatable, Sendable {
        public let display: Display
        public let program: Program?
        public let agentSince: Date?
    }

    public var visible: Visible {
        Visible(display: display, program: program, agentSince: agentSince)
    }

    /// Whether something happened here the user has not seen.
    public var hasUnseen: Bool { unseen != nil }

    /// The foreground process, polled. Returns the notice to post when a long command finished
    /// where the user was not looking.
    @discardableResult
    public mutating func observe(_ foreground: Foreground, at now: Date, seen: Bool) -> Notice? {
        switch foreground {
        case .shell:
            guard isRunning else { return nil }
            let since = shellSince ?? now
            shellSince = since
            shellObservations += 1
            // Between the jobs of a loop or `a && b` the shell is in front for a moment; while
            // the prompt's hooks run it is in front before the exit report arrives.
            if reportsExits {
                guard now.timeIntervalSince(since) >= Self.reportGrace else { return nil }
            } else {
                guard shellObservations >= 2 else { return nil }
            }
            return finish(code: 0, at: since, seen: seen)
        case .command, .program:
            if case .program(let p) = foreground { program = p } else { program = nil }
            if program?.isAgent != true { resetAgent() }
            shellSince = nil
            shellObservations = 0
            if !isRunning {
                isRunning = true
                startedAt = now
            }
            return nil
        }
    }

    /// The shell reported how the last command ended: the command is over.
    @discardableResult
    public mutating func exitReported(code: Int, at now: Date, seen: Bool) -> Notice? {
        reportsExits = true
        if isRunning { return finish(code: code, at: now, seen: seen) }
        // Ended already (the shell was seen in front twice before the report).
        if unseen == .finished, code != 0 { unseen = .failed(code) }
        return nil
    }

    private mutating func finish(code: Int, at end: Date, seen: Bool) -> Notice? {
        let ran = program
        let duration = startedAt.map { end.timeIntervalSince($0) } ?? 0
        resetAgent()
        isRunning = false
        program = nil
        startedAt = nil
        shellSince = nil
        shellObservations = 0
        guard !seen else { return nil }
        if unseen != .attention { unseen = code == 0 ? .finished : .failed(code) }
        guard duration >= Self.notifyAfter else { return nil }
        return Notice(kind: code == 0 ? .finished : .failed(code), program: ran, duration: duration)
    }

    /// An agent's screen, checked about once a second: whether it changed since the last check.
    /// Returns the notice to post when the agent finished a long turn where the user was not
    /// looking.
    @discardableResult
    public mutating func agentScreen(changed: Bool, at now: Date, seen: Bool) -> Notice? {
        guard program?.isAgent == true else {
            resetAgent()
            return nil
        }
        if agentSince == nil { agentSince = now }
        if changed {
            lastScreenChange = now
            seenSinceChange = seen
            if !isWorking {
                // Work is a screen that keeps changing: two changes within the quiet time.
                guard let first = firstChange, now.timeIntervalSince(first) < Self.agentQuiet else {
                    firstChange = now
                    return nil
                }
                isWorking = true
                workStarted = first
                agentSince = first
                firstChange = nil
            }
            return nil
        }
        seenSinceChange = seenSinceChange || seen
        guard isWorking, let lastScreenChange, now.timeIntervalSince(lastScreenChange) >= Self.agentQuiet else { return nil }
        isWorking = false
        agentSince = lastScreenChange
        let duration = workStarted.map { lastScreenChange.timeIntervalSince($0) } ?? 0
        workStarted = nil
        // The agent's turn is over: the user's, unless they saw it end.
        guard !seenSinceChange, unseen != .attention else { return nil }
        unseen = .attention
        guard duration >= Self.notifyAfter else { return nil }
        return Notice(kind: .waiting, program: program, duration: duration)
    }

    private mutating func resetAgent() {
        isWorking = false
        agentSince = nil
        lastScreenChange = nil
        workStarted = nil
        firstChange = nil
        seenSinceChange = false
    }

    /// A bell, or a program's notification (an agent waiting for the user). Notifies once until
    /// the user has looked: a program that rings in a loop is one notification.
    @discardableResult
    public mutating func attention(seen: Bool, message: String?) -> Notice? {
        guard !seen, unseen != .attention else { return nil }
        unseen = .attention
        return Notice(kind: .attention(message), program: program, duration: nil)
    }

    /// The user looked at the pane.
    public mutating func seen() {
        unseen = nil
    }
}

/// A macOS notification about a pane.
public struct Notice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case finished
        case failed(Int)
        case attention(String?)
        /// An agent finished its turn.
        case waiting
    }

    public let kind: Kind
    public let program: Program?
    public let duration: TimeInterval?

    public init(kind: Kind, program: Program?, duration: TimeInterval?) {
        self.kind = kind
        self.program = program
        self.duration = duration
    }

    /// The program's name, or the command that ran, or a plain word.
    public func title(command: String?) -> String {
        // A shell running a script or nested says less than the command that started it.
        if let program, !program.isShell { return program.name }
        if let command, !command.isEmpty { return command }
        return program?.name ?? "Command"
    }

    public var body: String {
        switch kind {
        case .finished: "Finished in \(Self.format(duration ?? 0))"
        case .failed(let code): "Failed (exit \(code)) after \(Self.format(duration ?? 0))"
        case .attention(let message): message.flatMap { $0.isEmpty ? nil : $0 } ?? "Needs your attention"
        case .waiting: "Waiting for you after \(Self.format(duration ?? 0))"
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min \(total % 60) s" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
