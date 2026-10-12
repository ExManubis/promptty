import PaneActivity
import XCTest

final class PaneActivityTests: XCTestCase {
    private let nvim = Program(id: "neovim", name: "Neovim")
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testStartsIdle() {
        XCTAssertEqual(PaneActivity().display, .idle)
    }

    func testAProgramInTheForegroundIsRunning() {
        var a = PaneActivity()
        a.observe(.program(nvim), at: t0, seen: true)
        XCTAssertEqual(a.display, .running)
        XCTAssertEqual(a.program, nvim)
    }

    // MARK: Without exit reports: the shell in front twice in a row

    func testTheShellSeenOnceIsAGapBetweenJobsNotTheEnd() {
        var a = PaneActivity()
        a.observe(.command, at: t0, seen: false)
        XCTAssertNil(a.observe(.shell, at: at(20), seen: false))
        XCTAssertEqual(a.display, .running)
        a.observe(.command, at: at(20.5), seen: false)
        XCTAssertNil(a.observe(.shell, at: at(30), seen: false))
        XCTAssertEqual(a.display, .running)
    }

    func testFinishingWhileLookingLeavesNothingUnseen() {
        var a = PaneActivity()
        a.observe(.program(nvim), at: t0, seen: true)
        a.observe(.shell, at: at(20), seen: true)
        XCTAssertNil(a.observe(.shell, at: at(20.5), seen: true))
        XCTAssertEqual(a.display, .idle)
        XCTAssertNil(a.program)
    }

    func testFinishingUnseenIsMarkedAndALongCommandNotifies() {
        var a = PaneActivity()
        a.observe(.command, at: t0, seen: false)
        a.observe(.shell, at: at(42), seen: false)
        let notice = a.observe(.shell, at: at(42.5), seen: false)
        XCTAssertEqual(a.display, .finished)
        XCTAssertEqual(notice, Notice(kind: .finished, program: nil, duration: 42))
    }

    func testAShortCommandFinishedUnseenIsMarkedButDoesNotNotify() {
        var a = PaneActivity()
        a.observe(.command, at: t0, seen: false)
        a.observe(.shell, at: at(3), seen: false)
        XCTAssertNil(a.observe(.shell, at: at(3.5), seen: false))
        XCTAssertEqual(a.display, .finished)
    }

    // MARK: With exit reports (OSC 133;D at the prompt)

    func testTheExitReportEndsTheCommandWithItsCode() {
        var a = PaneActivity()
        a.observe(.program(nvim), at: t0, seen: false)
        let notice = a.exitReported(code: 2, at: at(11), seen: false)
        XCTAssertEqual(a.display, .failed(2))
        XCTAssertEqual(notice, Notice(kind: .failed(2), program: nvim, duration: 11))
    }

    /// The shell is in front while the prompt's hooks run, before the exit report: that is not
    /// the end yet, so a failure is never announced as a success.
    func testAPaneThatReportsExitsWaitsForTheReport() {
        var a = PaneActivity()
        a.observe(.command, at: t0, seen: false)
        a.exitReported(code: 0, at: at(1), seen: false)
        a.seen()
        a.observe(.command, at: at(2), seen: false)
        XCTAssertNil(a.observe(.shell, at: at(30), seen: false))
        XCTAssertNil(a.observe(.shell, at: at(30.5), seen: false))
        XCTAssertEqual(a.display, .running)
        let notice = a.exitReported(code: 1, at: at(31), seen: false)
        XCTAssertEqual(notice?.kind, .failed(1))
        XCTAssertEqual(a.display, .failed(1))
    }

    func testAPaneThatReportsExitsStillEndsIfTheReportNeverComes() {
        var a = PaneActivity()
        a.exitReported(code: 0, at: t0, seen: true)
        a.observe(.command, at: at(1), seen: false)
        a.observe(.shell, at: at(20), seen: false)
        XCTAssertEqual(a.display, .running)
        XCTAssertNotNil(a.observe(.shell, at: at(23), seen: false))
        XCTAssertEqual(a.display, .finished)
    }

    func testALateFailureReportTurnsAFinishIntoAFailure() {
        var late = PaneActivity()
        late.observe(.command, at: t0, seen: false)
        late.observe(.shell, at: at(1), seen: false)
        late.observe(.shell, at: at(1.5), seen: false)
        late.exitReported(code: 1, at: at(1.6), seen: false)
        XCTAssertEqual(late.display, .failed(1))
    }

    func testLookingClearsWhatWasUnseen() {
        var a = PaneActivity()
        a.observe(.command, at: t0, seen: false)
        a.exitReported(code: 0, at: at(1), seen: false)
        a.seen()
        XCTAssertEqual(a.display, .idle)
    }

    // MARK: Attention

    func testAttentionWhileUnseenOutranksRunningAndNotifies() {
        var a = PaneActivity()
        a.observe(.program(nvim), at: t0, seen: false)
        let notice = a.attention(seen: false, message: "Waiting for input")
        XCTAssertEqual(a.display, .attention)
        XCTAssertEqual(notice, Notice(kind: .attention("Waiting for input"), program: nvim, duration: nil))
        a.seen()
        XCTAssertEqual(a.display, .running)
    }

    /// A program that rings the bell in a loop notifies once, until the user has looked.
    func testRepeatedAttentionNotifiesOnceUntilSeen() {
        var a = PaneActivity()
        XCTAssertNotNil(a.attention(seen: false, message: nil))
        XCTAssertNil(a.attention(seen: false, message: nil))
        XCTAssertNil(a.attention(seen: false, message: "again"))
        a.seen()
        XCTAssertNotNil(a.attention(seen: false, message: nil))
    }

    func testAttentionWhileLookingIsIgnored() {
        var a = PaneActivity()
        XCTAssertNil(a.attention(seen: true, message: nil))
        XCTAssertEqual(a.display, .idle)
    }

    func testAFinishDoesNotHideAnAttention() {
        var a = PaneActivity()
        a.observe(.program(nvim), at: t0, seen: false)
        a.attention(seen: false, message: nil)
        a.exitReported(code: 1, at: at(1), seen: false)
        XCTAssertEqual(a.display, .attention)
    }

    func testAnotherProgramTakingOverKeepsTheStartTime() {
        var a = PaneActivity()
        a.observe(.program(nvim), at: t0, seen: false)
        let git = Program(id: "git", name: "git")
        a.observe(.program(git), at: at(5), seen: false)
        XCTAssertEqual(a.program, git)
        XCTAssertEqual(a.exitReported(code: 0, at: at(15), seen: false)?.duration, 15)
    }

    func testTabsShowTheirMostUrgentPane() {
        XCTAssertEqual([PaneActivity.Display.running, .finished, .idle].max(), .finished)
        XCTAssertEqual([PaneActivity.Display.failed(1), .attention, .running].max(), .attention)
        XCTAssertEqual([PaneActivity.Display.finished, .failed(3)].max(), .failed(3))
        XCTAssertEqual([PaneActivity.Display.idle, .running].max(), .running)
    }

    func testNoticeText() {
        let zsh = Program(id: "zsh", name: "zsh", isShell: true)
        XCTAssertEqual(Notice(kind: .finished, program: nil, duration: 42).body, "Finished in 42 s")
        XCTAssertEqual(Notice(kind: .failed(1), program: nvim, duration: 125).body, "Failed (exit 1) after 2 min 5 s")
        XCTAssertEqual(Notice(kind: .attention("Claude needs your permission"), program: nil, duration: nil).body, "Claude needs your permission")
        XCTAssertEqual(Notice(kind: .attention(nil), program: nvim, duration: nil).body, "Needs your attention")
        XCTAssertEqual(Notice(kind: .finished, program: nvim, duration: 12).title(command: nil), "Neovim")
        XCTAssertEqual(Notice(kind: .finished, program: nil, duration: 12).title(command: "make test"), "make test")
        XCTAssertEqual(Notice(kind: .finished, program: nil, duration: 12).title(command: nil), "Command")
        // A nested shell or `bash script.sh`: the command says more than "zsh".
        XCTAssertEqual(Notice(kind: .finished, program: zsh, duration: 12).title(command: "bash build.sh"), "bash build.sh")
    }
}
