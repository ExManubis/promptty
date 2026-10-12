import PaneActivity
import XCTest

final class PaneActivityTests: XCTestCase {
    private let nvim = Program(id: "neovim", name: "Neovim")
    private let sleep: Program? = nil
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

    func testFinishingWhileLookingLeavesNothingUnseen() {
        var a = PaneActivity()
        a.observe(.program(nvim), at: t0, seen: true)
        XCTAssertNil(a.observe(.shell, at: at(20), seen: true))
        XCTAssertEqual(a.display, .idle)
        XCTAssertNil(a.program)
    }

    func testFinishingUnseenIsMarkedAndALongCommandNotifies() {
        var a = PaneActivity()
        a.observe(.command, at: t0, seen: false)
        a.exitReported(code: 0)
        let notice = a.observe(.shell, at: at(42), seen: false)
        XCTAssertEqual(a.display, .finished)
        XCTAssertEqual(notice, Notice(kind: .finished, program: nil, duration: 42))
    }

    func testAShortCommandFinishedUnseenIsMarkedButDoesNotNotify() {
        var a = PaneActivity()
        a.observe(.command, at: t0, seen: false)
        XCTAssertNil(a.observe(.shell, at: at(3), seen: false))
        XCTAssertEqual(a.display, .finished)
    }

    func testAFailureReportedBeforeOrAfterTheShellReturnsIsAFailure() {
        var a = PaneActivity()
        a.observe(.program(nvim), at: t0, seen: false)
        a.exitReported(code: 2)
        let notice = a.observe(.shell, at: at(11), seen: false)
        XCTAssertEqual(a.display, .failed(2))
        XCTAssertEqual(notice?.kind, .failed(2))
        XCTAssertEqual(notice?.program, nvim)

        var late = PaneActivity()
        late.observe(.command, at: t0, seen: false)
        late.observe(.shell, at: at(1), seen: false)
        late.exitReported(code: 1)
        XCTAssertEqual(late.display, .failed(1))
    }

    func testLookingClearsWhatWasUnseen() {
        var a = PaneActivity()
        a.observe(.command, at: t0, seen: false)
        a.observe(.shell, at: at(1), seen: false)
        a.seen()
        XCTAssertEqual(a.display, .idle)
    }

    func testAttentionWhileUnseenOutranksRunningAndNotifies() {
        var a = PaneActivity()
        a.observe(.program(nvim), at: t0, seen: false)
        let notice = a.attention(seen: false, message: "Waiting for input")
        XCTAssertEqual(a.display, .attention)
        XCTAssertEqual(notice, Notice(kind: .attention("Waiting for input"), program: nvim, duration: nil))
        a.seen()
        XCTAssertEqual(a.display, .running)
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
        a.exitReported(code: 1)
        a.observe(.shell, at: at(1), seen: false)
        XCTAssertEqual(a.display, .attention)
    }

    func testAnotherProgramTakingOverKeepsTheStartTime() {
        var a = PaneActivity()
        a.observe(.program(nvim), at: t0, seen: false)
        let git = Program(id: "git", name: "git")
        a.observe(.program(git), at: at(5), seen: false)
        XCTAssertEqual(a.program, git)
        XCTAssertEqual(a.observe(.shell, at: at(15), seen: false)?.duration, 15)
    }

    func testTabsShowTheirMostUrgentPane() {
        XCTAssertEqual([PaneActivity.Display.running, .finished, .idle].max(), .finished)
        XCTAssertEqual([PaneActivity.Display.failed(1), .attention, .running].max(), .attention)
        XCTAssertEqual([PaneActivity.Display.finished, .failed(3)].max(), .failed(3))
        XCTAssertEqual([PaneActivity.Display.idle, .running].max(), .running)
    }

    func testNoticeText() {
        XCTAssertEqual(Notice(kind: .finished, program: nil, duration: 42).body, "Finished in 42 s")
        XCTAssertEqual(Notice(kind: .failed(1), program: nvim, duration: 125).body, "Failed (exit 1) after 2 min 5 s")
        XCTAssertEqual(Notice(kind: .attention("Claude needs your permission"), program: nil, duration: nil).body, "Claude needs your permission")
        XCTAssertEqual(Notice(kind: .attention(nil), program: nvim, duration: nil).body, "Needs your attention")
        XCTAssertEqual(Notice(kind: .finished, program: nvim, duration: 12).title(command: nil), "Neovim")
        XCTAssertEqual(Notice(kind: .finished, program: nil, duration: 12).title(command: "make test"), "make test")
        XCTAssertEqual(Notice(kind: .finished, program: nil, duration: 12).title(command: nil), "Command")
    }
}
