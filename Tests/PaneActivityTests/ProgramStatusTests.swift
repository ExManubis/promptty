import PaneActivity
import XCTest

/// Programs that say what they do through OSC 7501, the Program Status Protocol.
final class ProgramStatusTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func records(_ reports: ProgramStatusReport...) -> ProgramStatusRecords {
        var r = ProgramStatusRecords()
        for (i, report) in reports.enumerated() { r.apply(report, at: at(Double(i))) }
        return r
    }

    // MARK: Records

    func testAReportReplacesItsRecordWhole() {
        var r = records(.init(state: .working, progress: 40, title: "Building"))
        r.apply(.init(state: .working), at: at(5))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.current?.report, .init(state: .working))
        // The same state again: it began when it first did.
        XCTAssertEqual(r.current?.since, at(0))
        r.apply(.init(state: .done), at: at(9))
        XCTAssertEqual(r.current?.since, at(9))
    }

    func testClearRemovesARecordAndThoseUnderIt() {
        var r = records(.init(state: .working, id: "deploy"), .init(state: .working, id: "deploy/us-east"),
                        .init(state: .working, id: "deployment"), .init(state: .idle))
        r.apply(.init(state: .clear, id: "deploy"), at: at(9))
        XCTAssertEqual(r.count, 2)
        r.apply(.init(state: .clear), at: at(10))
        XCTAssertTrue(r.isEmpty)
    }

    func testTheMostUrgentRecordShows() {
        let r = records(.init(state: .working, id: "a"), .init(state: .done, id: "b"),
                        .init(state: .blocked, kind: .question, id: "c"), .init(state: .idle))
        XCTAssertEqual(r.current?.report.id, "c")
        let permission = records(.init(state: .blocked, kind: .question, id: "c"), .init(state: .blocked, kind: .permission, id: "d"))
        XCTAssertEqual(permission.current?.report.id, "d")
        // Equally urgent: the program's own record.
        let own = records(.init(state: .working, id: "z"), .init(state: .working))
        XCTAssertNil(own.current?.report.id)
    }

    /// The program quitting or a new prompt ends work underway; finished work stays until seen.
    func testWorkEndsWithTheProgramAndFinishedWorkWhenSeen() {
        var r = records(.init(state: .working, id: "a"), .init(state: .blocked, id: "b"),
                        .init(state: .done, id: "c"), .init(state: .error, id: "d"), .init(state: .idle))
        r.endWork()
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.current?.report.id, "d")
        r.seen()
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.current?.report.state, .idle)
    }

    func testTheLeastRecentlyReportedRecordGoesPastTheCap() {
        var r = ProgramStatusRecords()
        for i in 0...256 { r.apply(.init(state: .working, id: "job\(i)"), at: at(Double(i))) }
        r.apply(.init(state: .working, id: "job1"), at: at(300))
        r.apply(.init(state: .error, id: "new"), at: at(301))
        XCTAssertEqual(r.count, 256)
        r.apply(.init(state: .clear, id: "job1"), at: at(302))
        XCTAssertEqual(r.count, 255, "job1 was reported again, so it stayed")
    }

    // MARK: The pane's activity

    private let cargo = Program(id: "cargo", name: "cargo", isAgent: false)

    private func running(_ program: Program?) -> PaneActivity {
        var a = PaneActivity()
        a.observe(program.map { .program($0) } ?? .command, at: t0, seen: false)
        return a
    }

    func testReportsMapOntoTheAgentStates() {
        let cases: [(ProgramStatusReport, PaneActivity.AgentReport?)] = [
            (.init(state: .idle), .ready),
            (.init(state: .working, title: "Compiling"), .working(tool: "Compiling")),
            (.init(state: .blocked, kind: .permission, title: "Deploy", message: "Allow deploy?"), .permission("Allow deploy?")),
            (.init(state: .blocked, kind: .auth, title: "Log in"), .waitingForInput("Log in")),
            (.init(state: .done), .turnEnded),
            (.init(state: .error, message: "Tests failed"), .failed("Tests failed")),
            (.init(state: .clear), nil),
        ]
        for (report, expected) in cases { XCTAssertEqual(report.agentReport, expected, "\(report.state)") }
    }

    /// Any program may report, not only agents, and its report survives the foreground polls.
    func testAnyProgramReportsItsState() {
        var a = running(cargo)
        a.programReported(.working(tool: "Compiling"), since: at(1), at: at(1), seen: false)
        a.observe(.program(cargo), at: at(2), seen: false)
        XCTAssertEqual(a.display, .working)
        XCTAssertEqual(a.visible.tool, "Compiling")
        let notice = a.programReported(.permission("Allow deploy?"), since: at(3), at: at(3), seen: false)
        XCTAssertEqual(notice?.kind, .permission("Allow deploy?"))
        a.observe(.command, at: at(4), seen: false)
        XCTAssertEqual(a.display, .permission)
    }

    func testAnErrorNeedsAttention() {
        var a = running(nil)
        a.programReported(.working(tool: nil), since: at(1), at: at(1), seen: false)
        let notice = a.programReported(.failed("Tests failed"), since: at(5), at: at(5), seen: false)
        XCTAssertEqual(notice?.kind, .attention("Tests failed"))
        XCTAssertEqual(a.display, .attention)
        // Reported again at the next tick: no second notice.
        XCTAssertNil(a.programReported(.failed("Tests failed"), since: at(5), at: at(6), seen: false))
    }

    func testWhenReportsEndTheProgramIsReadAsAnyOther() {
        var a = running(cargo)
        a.programReported(.working(tool: nil), since: at(1), at: at(1), seen: false)
        a.programStatusEnded()
        XCTAssertEqual(a.display, .running)
        // An agent keeps its state for its screen or hooks to go on from.
        var claude = running(Program(id: "claude", name: "Claude Code", isAgent: true))
        claude.programReported(.working(tool: nil), since: at(1), at: at(1), seen: false)
        claude.programStatusEnded()
        XCTAssertEqual(claude.display, .working)
    }
}
