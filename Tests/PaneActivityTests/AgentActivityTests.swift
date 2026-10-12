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

    func testAChangingScreenIsWorking() {
        var a = agent()
        a.agentScreen(changed: true, at: at(1), seen: false)
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
        XCTAssertNil(a.agentScreen(changed: false, at: at(5), seen: false))
        XCTAssertEqual(a.display, .attention)
    }

    func testGoingQuietWhileLookingIsJustWaiting() {
        var a = agent()
        a.agentScreen(changed: true, at: at(1), seen: true)
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

    func testTheAgentQuittingEndsItsWork() {
        var a = agent()
        a.agentScreen(changed: true, at: at(1), seen: false)
        a.observe(.shell, at: at(2), seen: true)
        a.observe(.shell, at: at(2.5), seen: true)
        XCTAssertFalse(a.isWorking)
        XCTAssertNil(a.agentSince)
    }

    func testWorkingRanksBetweenRunningAndFinished() {
        XCTAssertEqual([PaneActivity.Display.running, .working].max(), .working)
        XCTAssertEqual([PaneActivity.Display.working, .finished].max(), .finished)
    }
}
