import AgentHooks
import XCTest

final class AgentHookStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func state(_ events: [(HookEvent, HookPayload)]) -> AgentHookState {
        var s = AgentHookState()
        for (i, (event, payload)) in events.enumerated() { s.apply(event, payload, at: at(Double(i))) }
        return s
    }

    func testStartsWithNothingKnown() {
        let s = AgentHookState()
        XCTAssertNil(s.phase)
        XCTAssertFalse(s.reportsEveryChange)
        XCTAssertFalse(s.isActive(at: t0, agentInFront: true))
    }

    func testSessionStartKnowsTheSessionAndWaitsForAPrompt() {
        let s = state([(.sessionStart, HookPayload(sessionID: "s1", transcriptPath: "/t.jsonl", source: "startup"))])
        XCTAssertEqual(s.phase, .ready)
        XCTAssertEqual(s.sessionID, "s1")
        XCTAssertEqual(s.transcriptPath, "/t.jsonl")
        XCTAssertTrue(s.reportsEveryChange)
    }

    func testAPromptIsWork() {
        let s = state([(.sessionStart, HookPayload()), (.userPromptSubmit, HookPayload(sessionID: "s9", transcriptPath: "/t9"))])
        XCTAssertEqual(s.phase, .working)
        // Known from any event, not only SessionStart.
        XCTAssertEqual(s.sessionID, "s9")
        XCTAssertEqual(s.transcriptPath, "/t9")
        XCTAssertNil(s.tool)
        XCTAssertEqual(s.since, at(1))
    }

    func testToolUseRecordsTheToolWhileItRuns() {
        var s = state([(.userPromptSubmit, HookPayload()), (.preToolUse, HookPayload(toolName: "Bash"))])
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.tool, "Bash")
        // Still the same stretch of work: since does not move.
        XCTAssertEqual(s.since, at(0))
        s.apply(.postToolUse, HookPayload(toolName: "Bash"), at: at(5))
        XCTAssertEqual(s.phase, .working)
        XCTAssertNil(s.tool)
        XCTAssertEqual(s.since, at(0))
    }

    func testAPermissionPromptNeedsTheUser() {
        let s = state([(.preToolUse, HookPayload(toolName: "Bash")),
                       (.notification, HookPayload(message: "Claude needs your permission to use Bash"))])
        XCTAssertEqual(s.phase, .permission)
        XCTAssertEqual(s.message, "Claude needs your permission to use Bash")
        XCTAssertEqual(s.tool, "Bash")
        XCTAssertEqual(s.since, at(1))
    }

    func testWaitingForInputIsNotAPermissionPrompt() {
        let s = state([(.stop, HookPayload()), (.notification, HookPayload(message: "Claude is waiting for your input"))])
        XCTAssertEqual(s.phase, .waitingForInput)
        XCTAssertEqual(s.message, "Claude is waiting for your input")
    }

    func testANotificationTypeOverridesTheMessage() {
        let s = state([(.notification, HookPayload(message: "Claude needs your attention", notificationType: "permission_prompt"))])
        XCTAssertEqual(s.phase, .permission)
    }

    func testANotificationThatAsksNothingChangesNothing() {
        var s = state([(.userPromptSubmit, HookPayload())])
        s.apply(.notification, HookPayload(message: "Signed in", notificationType: "auth_success"), at: at(9))
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.lastEvent, at(9))
    }

    func testStopIsYourTurn() {
        let s = state([(.userPromptSubmit, HookPayload()), (.preToolUse, HookPayload(toolName: "Edit")), (.stop, HookPayload())])
        XCTAssertEqual(s.phase, .turnEnded)
        XCTAssertNil(s.tool)
        XCTAssertEqual(s.since, at(2))
    }

    /// A subagent finishing hands its result back to the main agent, which carries on: not the
    /// user's turn.
    func testASubagentStoppingIsNotYourTurn() {
        let s = state([(.userPromptSubmit, HookPayload()), (.subagentStop, HookPayload())])
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.lastEvent, at(1))
    }

    func testAnsweringAPermissionPromptIsWorkAgain() {
        var s = state([(.preToolUse, HookPayload(toolName: "Bash")),
                       (.notification, HookPayload(message: "Claude needs your permission to use Bash"))])
        s.userResponded(at: at(10))
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.tool, "Bash")
        XCTAssertNil(s.message)
        // Anything else is not a prompt answered.
        var t = state([(.stop, HookPayload())])
        t.userResponded(at: at(10))
        XCTAssertEqual(t.phase, .turnEnded)
    }

    /// Interrupting a turn runs no hook: no event, and a still screen, end the work.
    func testAStillScreenWithoutEventsIsAnInterruptedTurn() {
        var s = state([(.userPromptSubmit, HookPayload()), (.preToolUse, HookPayload(toolName: "Bash"))])  // last event at 1
        // The screen moved recently, or an event came lately: still working.
        XCTAssertFalse(s.screenStill(since: at(5), at: at(7)))
        XCTAssertFalse(s.screenStill(since: at(1), at: at(5.5)))
        XCTAssertEqual(s.phase, .working)
        XCTAssertTrue(s.screenStill(since: at(3), at: at(7)))
        XCTAssertEqual(s.phase, .ready)
        XCTAssertNil(s.tool)
        XCTAssertEqual(s.since, at(3))
        // The next prompt is work again.
        s.apply(.userPromptSubmit, HookPayload(), at: at(20))
        XCTAssertEqual(s.phase, .working)
    }

    /// A permission prompt or a finished turn is still, and stays what it is.
    func testOnlyWorkIsEndedByAStillScreen() {
        var p = state([(.notification, HookPayload(message: "Claude needs your permission to use Bash"))])
        XCTAssertFalse(p.screenStill(since: at(0), at: at(600)))
        XCTAssertEqual(p.phase, .permission)
        var t = state([(.stop, HookPayload())])
        XCTAssertFalse(t.screenStill(since: at(0), at: at(600)))
        XCTAssertEqual(t.phase, .turnEnded)
    }

    func testSessionEndForgetsTheSession() {
        let s = state([(.sessionStart, HookPayload(sessionID: "s1", transcriptPath: "/t")), (.userPromptSubmit, HookPayload()), (.sessionEnd, HookPayload())])
        XCTAssertEqual(s, AgentHookState())
    }

    /// Compacting starts a new session part-way through a turn: the work goes on.
    func testACompactingSessionStartKeepsTheWork() {
        let s = state([(.userPromptSubmit, HookPayload()), (.sessionStart, HookPayload(sessionID: "s2", source: "compact"))])
        XCTAssertEqual(s.phase, .working)
        XCTAssertEqual(s.sessionID, "s2")
        // Starting afresh (or resuming, or clearing) is waiting for a prompt again.
        let fresh = state([(.userPromptSubmit, HookPayload()), (.sessionStart, HookPayload(source: "resume"))])
        XCTAssertEqual(fresh.phase, .ready)
    }

    func testCodexTurnCompleteIsYourTurnButNotEveryChange() {
        let s = state([(.codexNotify, HookPayload(type: "agent-turn-complete"))])
        XCTAssertEqual(s.phase, .turnEnded)
        XCTAssertFalse(s.reportsEveryChange)
        XCTAssertFalse(s.isActive(at: at(1), agentInFront: true))
        // Other Codex notifications say nothing PrompTTY uses.
        let other = state([(.codexNotify, HookPayload(type: "something-else"))])
        XCTAssertNil(other.phase)
    }

    func testHooksStayInChargeWhileTheyReportOrTheAgentRuns() {
        let s = state([(.userPromptSubmit, HookPayload())])
        XCTAssertTrue(s.isActive(at: at(5), agentInFront: false))
        XCTAssertTrue(s.isActive(at: at(3600), agentInFront: true))
        XCTAssertTrue(s.isActive(at: at(AgentHookState.staleAfter), agentInFront: false))
        // Ten minutes without a word and no agent in front: the screen is watched again.
        XCTAssertFalse(s.isActive(at: at(AgentHookState.staleAfter + 1), agentInFront: false))
    }
}
