import PaneActivity
import XCTest

/// An agent that says what it does (Claude Code's hooks), rather than one read off its screen.
final class AgentReportTests: XCTestCase {
    private let claude = Program(id: "claude", name: "Claude Code", isAgent: true)
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func agent() -> PaneActivity {
        var a = PaneActivity()
        a.observe(.program(claude), at: t0, seen: false)
        return a
    }

    func testWorkingShowsTheTool() {
        var a = agent()
        XCTAssertNil(a.agentReported(.working(tool: nil), since: at(1), at: at(1), seen: false))
        XCTAssertEqual(a.display, .working)
        XCTAssertEqual(a.agentSince, at(1))
        a.agentReported(.working(tool: "Bash"), since: at(1), at: at(2), seen: false)
        XCTAssertEqual(a.visible.tool, "Bash")
        XCTAssertEqual(a.agentSince, at(1))
    }

    func testAPermissionPromptShowsAndNotifiesUnseen() {
        var a = agent()
        a.agentReported(.working(tool: "Bash"), since: at(1), at: at(1), seen: false)
        let notice = a.agentReported(.permission("Claude needs your permission to use Bash"), since: at(5), at: at(5), seen: false)
        XCTAssertEqual(notice, Notice(kind: .permission("Claude needs your permission to use Bash"), program: claude, duration: nil))
        XCTAssertEqual(notice?.body, "Claude needs your permission to use Bash")
        XCTAssertEqual(Notice(kind: .permission(nil), program: claude, duration: nil).body, "Needs your permission")
        XCTAssertEqual(a.display, .permission)
        XCTAssertEqual(a.agentSince, at(5))
        // Reported again (each tick): no second notice.
        XCTAssertNil(a.agentReported(.permission("Claude needs your permission to use Bash"), since: at(5), at: at(6), seen: false))
    }

    /// A prompt for permission stands until answered, looked at or not.
    func testAPermissionPromptSeenStillShows() {
        var a = agent()
        XCTAssertNil(a.agentReported(.permission(nil), since: at(5), at: at(5), seen: true))
        XCTAssertEqual(a.display, .permission)
        a.seen()
        XCTAssertEqual(a.display, .permission)
        a.agentReported(.working(tool: nil), since: at(8), at: at(8), seen: true)
        XCTAssertEqual(a.display, .working)
    }

    /// Answered without the pane in view: back to work, nothing left to see.
    func testAPermissionPromptAnsweredUnseenIsNotYourTurn() {
        var a = agent()
        a.agentReported(.working(tool: "Bash"), since: at(1), at: at(1), seen: false)
        a.agentReported(.permission(nil), since: at(5), at: at(5), seen: false)
        a.agentReported(.working(tool: nil), since: at(9), at: at(9), seen: false)
        XCTAssertEqual(a.display, .working)
        XCTAssertFalse(a.hasUnseen)
        // A turn that had ended unseen before stays unseen.
        var b = agent()
        b.agentReported(.working(tool: nil), since: at(1), at: at(1), seen: false)
        b.agentReported(.turnEnded, since: at(3), at: at(3), seen: false)
        b.agentReported(.permission(nil), since: at(5), at: at(5), seen: false)
        b.agentReported(.working(tool: nil), since: at(9), at: at(9), seen: false)
        XCTAssertTrue(b.hasUnseen)
    }

    func testPermissionOutranksEverything() {
        XCTAssertGreaterThan(PaneActivity.Display.permission, .attention)
    }

    func testTheEndOfALongTurnUnseenIsYourTurnAndNotifies() {
        var a = agent()
        a.agentReported(.working(tool: nil), since: at(1), at: at(1), seen: false)
        let notice = a.agentReported(.turnEnded, since: at(41), at: at(41), seen: false)
        XCTAssertEqual(notice, Notice(kind: .waiting, program: claude, duration: 40))
        XCTAssertEqual(notice?.body, "Done after 40 s, your turn")
        XCTAssertEqual(a.display, .attention)
        XCTAssertEqual(a.agentSince, at(41))
        XCTAssertNil(a.visible.tool)
    }

    /// The turn counts from its start, through a permission prompt on the way.
    func testATurnThroughAPermissionPromptCountsFromItsStart() {
        var a = agent()
        a.agentReported(.working(tool: nil), since: at(1), at: at(1), seen: true)
        a.agentReported(.permission(nil), since: at(5), at: at(5), seen: true)
        a.agentReported(.working(tool: "Bash"), since: at(9), at: at(9), seen: true)
        XCTAssertEqual(a.agentSince, at(1))
        XCTAssertEqual(a.agentReported(.turnEnded, since: at(31), at: at(31), seen: false)?.duration, 30)
    }

    func testAShortTurnOrOneSeenDoesNotNotify() {
        var a = agent()
        a.agentReported(.working(tool: nil), since: at(1), at: at(1), seen: false)
        XCTAssertNil(a.agentReported(.turnEnded, since: at(3), at: at(3), seen: false))
        XCTAssertEqual(a.display, .attention)
        var b = agent()
        b.agentReported(.working(tool: nil), since: at(1), at: at(1), seen: false)
        XCTAssertNil(b.agentReported(.turnEnded, since: at(60), at: at(60), seen: true))
        XCTAssertEqual(b.display, .running)
    }

    func testWaitingForInputUnseenNeedsTheUserOnce() {
        var a = agent()
        let notice = a.agentReported(.waitingForInput("Claude is waiting for your input"), since: at(1), at: at(1), seen: false)
        XCTAssertEqual(notice?.kind, .attention("Claude is waiting for your input"))
        XCTAssertEqual(a.display, .attention)
        // After a turn that already said so: nothing more.
        var b = agent()
        b.agentReported(.working(tool: nil), since: at(1), at: at(1), seen: false)
        b.agentReported(.turnEnded, since: at(3), at: at(3), seen: false)
        XCTAssertNil(b.agentReported(.waitingForInput("Claude is waiting for your input"), since: at(63), at: at(63), seen: false))
        // Still your turn since the turn ended.
        XCTAssertEqual(b.agentSince, at(3))
    }

    func testReadyIsQuietWaiting() {
        var a = agent()
        XCTAssertNil(a.agentReported(.ready, since: at(1), at: at(1), seen: false))
        XCTAssertEqual(a.display, .running)
        XCTAssertEqual(a.agentSince, at(1))
    }

    /// Codex says only that a turn ended; its work is read off the screen.
    func testATurnEndedOnceEndsWorkSeenOnTheScreen() {
        var a = agent()
        a.agentScreen(changed: false, at: at(0), seen: false)
        a.agentScreen(changed: true, at: at(1), seen: false)
        a.agentScreen(changed: true, at: at(1.5), seen: false)
        XCTAssertTrue(a.isWorking)
        let notice = a.agentTurnEnded(at: at(30), seen: false)
        XCTAssertEqual(notice?.kind, .waiting)
        XCTAssertEqual(a.display, .attention)
        // The screen going quiet afterwards says nothing more.
        XCTAssertNil(a.agentScreen(changed: false, at: at(40), seen: false))
        // And the next turn ends the same way.
        a.seen()
        a.agentScreen(changed: true, at: at(50), seen: false)
        a.agentScreen(changed: true, at: at(50.5), seen: false)
        XCTAssertEqual(a.agentTurnEnded(at: at(70), seen: false)?.kind, .waiting)
    }

    func testReportsAreForAgentsOnly() {
        var a = PaneActivity()
        a.observe(.command, at: t0, seen: false)
        XCTAssertNil(a.agentReported(.permission(nil), since: at(1), at: at(1), seen: false))
        XCTAssertEqual(a.display, .running)
    }

    func testTheAgentLeavingForgetsWhatItReported() {
        var a = agent()
        a.agentReported(.permission(nil), since: at(1), at: at(1), seen: true)
        a.observe(.command, at: at(2), seen: true)
        XCTAssertEqual(a.display, .running)
        XCTAssertNil(a.visible.tool)
    }
}
