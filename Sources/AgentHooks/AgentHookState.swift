import Foundation

/// What a pane's agent last reported through its hooks. Claude Code's hooks report every change
/// (a prompt, each tool, a permission prompt, the end of a turn), so while they arrive they say
/// exactly what the agent does; Codex reports only the end of a turn.
public struct AgentHookState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// A session started; no prompt yet.
        case ready
        case working
        /// A permission prompt waits for the user.
        case permission
        /// The agent waits for the user to write (a question, or a turn long over).
        case waitingForInput
        /// The agent finished its turn: the user's turn.
        case turnEnded
    }

    public private(set) var phase: Phase?
    /// The tool running now (between PreToolUse and PostToolUse), or asking for permission.
    public private(set) var tool: String?
    /// The last Notification's text, while it stands.
    public private(set) var message: String?
    public private(set) var sessionID: String?
    public private(set) var transcriptPath: String?
    /// When the phase began.
    public private(set) var since: Date?
    public private(set) var lastEvent: Date?
    /// Claude Code's hooks are in use: they report every change, so they, not the screen, say what
    /// the agent does.
    public private(set) var reportsEveryChange = false

    /// With no event for this long and no agent in front any more, the hooks are taken to be gone
    /// (the agent was killed before it could say so).
    public static let staleAfter: TimeInterval = 10 * 60

    public init() {}

    public mutating func apply(_ event: HookEvent, _ payload: HookPayload, at now: Date) {
        if event == .sessionEnd {
            self = AgentHookState()
            return
        }
        lastEvent = now
        if event != .codexNotify { reportsEveryChange = true }
        switch event {
        case .sessionStart:
            sessionID = payload.sessionID ?? sessionID
            transcriptPath = payload.transcriptPath ?? transcriptPath
            // Compacting starts a new session in the middle of a turn: the work goes on.
            if payload.source != "compact" || phase == nil { enter(.ready, at: now) }
        case .userPromptSubmit:
            enter(.working, at: now)
        case .preToolUse:
            enter(.working, at: now)
            tool = payload.toolName
        case .postToolUse:
            enter(.working, at: now)
        case .notification:
            switch payload.notificationKind {
            case .permission:
                // The tool asking stays named.
                let asking = tool
                enter(.permission, at: now)
                tool = asking
                message = payload.message
            case .input:
                enter(.waitingForInput, at: now)
                message = payload.message
            case .none:
                break
            }
        case .stop:
            enter(.turnEnded, at: now)
        case .subagentStop:
            // A subagent hands its result back to the main agent, which carries on.
            break
        case .codexNotify:
            if payload.type == "agent-turn-complete" { enter(.turnEnded, at: now) }
        case .sessionEnd:
            break
        }
    }

    /// The user typed in the pane. At a permission prompt that answers it, and no hook says so: the
    /// agent goes on (or stops, which its Stop hook reports).
    public mutating func userResponded(at now: Date) {
        guard phase == .permission else { return }
        let asking = tool
        enter(.working, at: now)
        tool = asking
    }

    /// Whether the hooks, not the screen, say what the pane's agent does: while they report, for
    /// as long as an agent runs in front, and for ten minutes after their last word.
    public func isActive(at now: Date, agentInFront: Bool) -> Bool {
        guard reportsEveryChange, let lastEvent else { return false }
        return agentInFront || now.timeIntervalSince(lastEvent) <= Self.staleAfter
    }

    /// Moves to a phase: `since` changes only with the phase; the tool and message are the new
    /// phase's to set.
    private mutating func enter(_ next: Phase, at now: Date) {
        if phase != next { since = now }
        phase = next
        tool = nil
        message = nil
    }
}
