import PaneActivity
import XCTest

final class AgentActivityTests: XCTestCase {
    private let claude = Program(id: "claude", name: "Claude Code", isAgent: true)
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// An agent in front, its screen still.
    private func agent() -> PaneActivity {
        var a = PaneActivity()
        a.observe(.program(claude), at: t0, seen: false)
        a.agentScreen(changed: false, at: t0, seen: false)
        return a
    }

    func testAgentsAreKnown() {
        for id in ["claude", "codex", "gemini", "copilot"] {
            XCTAssertEqual(ProgramCatalog.all.first { $0.id == id }?.isAgent, true, id)
        }
        XCTAssertEqual(ProgramCatalog.all.first { $0.id == "neovim" }?.isAgent, false)
    }

    func testAStillAgentIsWaitingAndShowsAsRunning() {
        let a = agent()
        XCTAssertFalse(a.isWorking)
        XCTAssertEqual(a.display, .running)
    }

    /// One change is not work: a clock in a status line, a keystroke echoed, a redraw.
    func testASingleChangeIsNotWork() {
        var a = agent()
        a.agentScreen(changed: true, at: at(1), seen: false)
        XCTAssertFalse(a.isWorking)
        a.agentScreen(changed: false, at: at(10), seen: false)
        a.agentScreen(changed: true, at: at(20), seen: false)
        XCTAssertFalse(a.isWorking)
    }

    func testAChangingScreenIsWorking() {
        var a = agent()
        a.agentScreen(changed: true, at: at(1), seen: false)
        a.agentScreen(changed: true, at: at(1.5), seen: false)
        XCTAssertTrue(a.isWorking)
        XCTAssertEqual(a.display, .working)
        XCTAssertEqual(a.agentSince, at(1))
        // A pause shorter than three seconds is still work (thinking between bursts).
        a.agentScreen(changed: false, at: at(3), seen: false)
        XCTAssertTrue(a.isWorking)
    }

    func testGoingQuietUnseenIsYourTurnAndALongTurnNotifies() {
        var a = agent()
        a.agentScreen(changed: true, at: at(1), seen: false)
        a.agentScreen(changed: true, at: at(1.5), seen: false)
        a.agentScreen(changed: true, at: at(40), seen: false)
        XCTAssertNil(a.agentScreen(changed: false, at: at(42), seen: false))
        let notice = a.agentScreen(changed: false, at: at(43), seen: false)
        XCTAssertFalse(a.isWorking)
        XCTAssertEqual(a.display, .attention)
        XCTAssertEqual(a.agentSince, at(40))
        XCTAssertEqual(notice, Notice(kind: .waiting, program: claude, duration: 39))
        XCTAssertEqual(notice?.body, "Waiting for you after 39 s")
    }

    func testAShortTurnIsYourTurnWithoutANotification() {
        var a = agent()
        a.agentScreen(changed: true, at: at(1), seen: false)
        a.agentScreen(changed: true, at: at(1.5), seen: false)
        XCTAssertNil(a.agentScreen(changed: false, at: at(5), seen: false))
        XCTAssertEqual(a.display, .attention)
    }

    func testGoingQuietWhileLookingIsJustWaiting() {
        var a = agent()
        a.agentScreen(changed: true, at: at(1), seen: true)
        a.agentScreen(changed: true, at: at(1.5), seen: true)
        XCTAssertNil(a.agentScreen(changed: false, at: at(30), seen: true))
        XCTAssertEqual(a.display, .running)
    }

    func testOtherProgramsScreensAreIgnored() {
        var a = PaneActivity()
        a.observe(.program(Program(id: "neovim", name: "Neovim")), at: t0, seen: false)
        a.agentScreen(changed: true, at: at(1), seen: false)
        XCTAssertFalse(a.isWorking)
        XCTAssertEqual(a.display, .running)
    }

    /// The user watched the turn end and switched away before the agent had been quiet for three
    /// seconds: they saw it, so it is not news.
    func testATurnThatEndedWhileLookingIsNotYourTurnAfterSwitchingAway() {
        var a = agent()
        a.agentScreen(changed: true, at: at(1), seen: true)
        a.agentScreen(changed: true, at: at(1.5), seen: true)
        a.agentScreen(changed: true, at: at(60), seen: true)
        XCTAssertTrue(a.isWorking)
        a.agentScreen(changed: false, at: at(61), seen: true)
        XCTAssertNil(a.agentScreen(changed: false, at: at(63), seen: false))
        XCTAssertFalse(a.isWorking)
        XCTAssertEqual(a.display, .running)
    }

    func testTheAgentQuittingEndsItsWork() {
        var a = agent()
        a.agentScreen(changed: true, at: at(1), seen: false)
        a.agentScreen(changed: true, at: at(1.5), seen: false)
        a.observe(.shell, at: at(2), seen: true)
        a.observe(.shell, at: at(2.5), seen: true)
        XCTAssertFalse(a.isWorking)
        XCTAssertNil(a.agentSince)
    }

    /// What views compare: only what they show, not the per-second bookkeeping.
    func testVisibleStateIgnoresTheScreenBookkeeping() {
        var a = agent()
        a.agentScreen(changed: true, at: at(1), seen: false)
        a.agentScreen(changed: true, at: at(1.5), seen: false)
        let before = a.visible
        a.agentScreen(changed: true, at: at(2), seen: false)
        XCTAssertEqual(a.visible, before)
    }

    func testWorkingRanksBetweenRunningAndFinished() {
        XCTAssertEqual([PaneActivity.Display.running, .working].max(), .working)
        XCTAssertEqual([PaneActivity.Display.working, .finished].max(), .finished)
    }
}
