import XCTest
@testable import CommandEditing

final class ShellPaneStateTests: XCTestCase {
    func testStartsAsAPlainTerminal() {
        let s = ShellPaneState()
        XCTAssertEqual(s.phase, .starting)
        XCTAssertNil(s.shellPID)
        XCTAssertNil(s.lastExit)
    }

    func testFirstPromptLearnsTheShellAndGoesIdle() {
        var s = ShellPaneState()
        XCTAssertTrue(s.promptReady(foregroundPID: 400))
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.shellPID, 400)
    }

    func testAnUnknownForegroundBeforeTheFirstPromptIsIgnored() {
        var s = ShellPaneState()
        XCTAssertFalse(s.promptReady(foregroundPID: 0))
        XCTAssertEqual(s.phase, .starting)
        XCTAssertNil(s.shellPID)
    }

    func testSubmittingRunsAndTheNextPromptReturnsToIdle() {
        var s = ShellPaneState()
        _ = s.promptReady(foregroundPID: 400)
        s.submitted()
        XCTAssertEqual(s.phase, .running)
        XCTAssertTrue(s.promptReady(foregroundPID: 400))
        XCTAssertEqual(s.phase, .idle)
    }

    func testAPwdReportFromAChildKeepsRunning() {
        var s = ShellPaneState()
        _ = s.promptReady(foregroundPID: 400)
        s.submitted()
        XCTAssertFalse(s.promptReady(foregroundPID: 512), "a nested shell or program reporting its directory")
        XCTAssertEqual(s.phase, .running)
    }

    func testPwdWhileIdleIsANoOp() {
        var s = ShellPaneState()
        _ = s.promptReady(foregroundPID: 400)
        XCTAssertFalse(s.promptReady(foregroundPID: 400))
        XCTAssertEqual(s.phase, .idle)
    }

    func testAnotherForegroundProcessSeenTwiceWhileIdleMeansRunning() {
        var s = ShellPaneState()
        _ = s.promptReady(foregroundPID: 400)
        s.foregroundChanged(to: 400)
        XCTAssertEqual(s.phase, .idle)
        s.foregroundChanged(to: 777)
        XCTAssertEqual(s.phase, .idle, "one sighting can be a hook's short-lived helper (tput)")
        s.foregroundChanged(to: 777)
        XCTAssertEqual(s.phase, .running)
    }

    func testABriefForegroundProcessDoesNotLeaveIdle() {
        var s = ShellPaneState()
        _ = s.promptReady(foregroundPID: 400)
        s.foregroundChanged(to: 777)
        s.foregroundChanged(to: 400)
        s.foregroundChanged(to: 778)
        XCTAssertEqual(s.phase, .idle)
    }

    func testForegroundChangesOutsideIdleAreIgnored() {
        var s = ShellPaneState()
        s.foregroundChanged(to: 777)
        XCTAssertEqual(s.phase, .starting)
    }

    func testSubmittingOnlyWorksWhenIdle() {
        var s = ShellPaneState()
        s.submitted()
        XCTAssertEqual(s.phase, .starting)
    }

    func testCommandFinishedRecordsTheExit() {
        var s = ShellPaneState()
        _ = s.promptReady(foregroundPID: 400)
        s.submitted()
        s.commandFinished(code: 1, durationNanoseconds: 2_500_000_000)
        XCTAssertEqual(s.lastExit, CommandExit(code: 1, duration: 2.5))
        XCTAssertEqual(s.phase, .running, "the next prompt, not the finish, returns to idle")
    }

    func testUnknownExitCodeIsKept() {
        var s = ShellPaneState()
        s.commandFinished(code: -1, durationNanoseconds: 0)
        XCTAssertEqual(s.lastExit?.code, -1)
    }
}
