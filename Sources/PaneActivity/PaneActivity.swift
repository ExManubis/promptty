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
        /// An agent asks for permission (to run a tool): it is stuck until the user answers.
        case permission

        private var rank: Int {
            switch self {
            case .idle: 0
            case .running: 1
            case .working: 2
            case .finished: 3
            case .failed: 4
            case .attention: 5
            case .permission: 6
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

    /// What the agent last said of itself (its hooks), if it says: reported again at every tick,
    /// so a report already applied changes nothing.
    private var lastReport: AgentReport?
    /// The agent waits for the user to allow a tool; it stands until the agent reports otherwise.
    private var awaitingPermission = false
    /// What is unseen is a permission prompt or a question in a turn, which goes once it is answered.
    private var unseenPermission = false
    /// The tool the agent runs (or asks to run), as it reports it.
    private var tool: String?

    /// Commands that take at least this long notify when they finish unseen.
    public static let notifyAfter: TimeInterval = 10
    /// With exit reports: how long the shell may be in front without one before the command is
    /// taken to have ended anyway.
    static let reportGrace: TimeInterval = 3

    public init() {}

    public var display: Display {
        if awaitingPermission { return .permission }
        return switch unseen {
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
        /// The tool an agent runs, when it says.
        public let tool: String?
    }

    public var visible: Visible {
        Visible(display: display, program: program, agentSince: agentSince, tool: tool)
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

    /// An agent's screen, checked every half second where the user looks and every 1.5 s elsewhere:
    /// whether it changed since the last check.
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

    /// What an agent says it does, through its hooks.
    public enum AgentReport: Equatable, Sendable {
        /// A session started: waiting for a first prompt.
        case ready
        case working(tool: String?)
        /// Asks to be allowed to use a tool; the agent's message.
        case permission(String?)
        /// Waits for the user to write; the agent's message.
        case waitingForInput(String?)
        /// Finished its turn.
        case turnEnded
    }

    /// The agent reported its state; `since` is when that state began. The hooks say exactly what
    /// the screen only suggests, so while they report, they alone set the agent's state. Returns
    /// the notice to post: a permission prompt, a question or a long turn's end the user did not
    /// see.
    @discardableResult
    public mutating func agentReported(_ report: AgentReport, since: Date, at now: Date, seen: Bool) -> Notice? {
        guard program?.isAgent == true, report != lastReport else { return nil }
        lastReport = report
        let busy = isWorking || awaitingPermission
        switch report {
        case .ready:
            isWorking = false
            awaitingPermission = false
            tool = nil
            workStarted = nil
            agentSince = since
            return nil
        case .working(let tool):
            self.tool = tool
            awaitingPermission = false
            // The prompt was answered (elsewhere, or without the pane coming into view): the agent
            // is not waiting for the user any more.
            if unseenPermission, unseen == .attention { unseen = nil }
            unseenPermission = false
            if !isWorking {
                isWorking = true
                // Back to work after a permission prompt: the same turn.
                workStarted = workStarted ?? since
                agentSince = workStarted
            }
            return nil
        case .permission(let message):
            awaitingPermission = true
            isWorking = false
            agentSince = since
            guard !seen else { return nil }
            if unseen != .attention { unseenPermission = true }
            unseen = .attention
            return Notice(kind: .permission(message), program: program, duration: nil)
        case .waitingForInput(let message):
            isWorking = false
            awaitingPermission = false
            tool = nil
            // A question in the middle of a turn (AskUserQuestion) is part of the turn, like a
            // permission prompt; after a turn there is no work to count.
            if !busy { workStarted = nil }
            if busy || agentSince == nil { agentSince = since }
            guard !seen, unseen != .attention else { return nil }
            unseen = .attention
            unseenPermission = busy
            return Notice(kind: .attention(message), program: program, duration: nil)
        case .turnEnded:
            return endTurn(at: since, seen: seen, busy: busy)
        }
    }

    /// The agent said its turn ended, and says nothing else (Codex): its work is read off the
    /// screen, its end is known exactly.
    @discardableResult
    public mutating func agentTurnEnded(at now: Date, seen: Bool) -> Notice? {
        guard program?.isAgent == true else { return nil }
        return endTurn(at: now, seen: seen, busy: true)
    }

    private mutating func endTurn(at end: Date, seen: Bool, busy: Bool) -> Notice? {
        let duration = workStarted.map { end.timeIntervalSince($0) } ?? 0
        isWorking = false
        awaitingPermission = false
        tool = nil
        workStarted = nil
        firstChange = nil
        if busy || agentSince == nil { agentSince = end }
        guard busy, !seen, unseen != .attention else { return nil }
        unseen = .attention
        guard duration >= Self.notifyAfter else { return nil }
        return Notice(kind: .waiting, program: program, duration: duration)
    }

    private mutating func resetAgent() {
        lastReport = nil
        unseenPermission = false
        awaitingPermission = false
        tool = nil
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
        unseenPermission = false
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
        /// An agent asks for permission to use a tool; its message.
        case permission(String?)
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
        case .waiting: "Done after \(Self.format(duration ?? 0)), your turn"
        case .permission(let message): message.flatMap { $0.isEmpty ? nil : $0 } ?? "Needs your permission"
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
