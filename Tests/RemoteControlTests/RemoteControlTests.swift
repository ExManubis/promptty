import Darwin
import XCTest
@testable import RemoteControl

final class ControlCommandLineTests: XCTestCase {
    private func request(_ args: [String]) throws -> ControlRequest {
        guard case .request(let r) = try ControlCommandLine.parse(args, caller: "C") else { throw XCTSkip("not a request") }
        return r
    }

    func testParsesCommandsTargetsAndFlagsInAnyOrder() throws {
        let r = try request(["-p", "logs", "send", "make", "test", "--enter", "--json"])
        XCTAssertEqual(r.command, "send")
        XCTAssertEqual(r.target, "logs")
        XCTAssertEqual(r.arguments, ["make", "test"])
        XCTAssertEqual(r.flags, ["enter", "json"])
        XCTAssertEqual(r.caller, "C")
    }

    func testEverythingAfterDoubleDashIsTheCommand() throws {
        let r = try request(["split", "down", "--cwd", "/tmp", "--", "npm", "run", "--watch"])
        XCTAssertEqual(r.arguments, ["down", "npm", "run", "--watch"])
        XCTAssertEqual(r.options, ["cwd": "/tmp"])
    }

    func testUsageErrors() {
        XCTAssertThrowsError(try ControlCommandLine.parse(["frobnicate"], caller: nil))
        XCTAssertThrowsError(try ControlCommandLine.parse(["split", "sideways"], caller: nil))
        XCTAssertThrowsError(try ControlCommandLine.parse(["focus"], caller: nil))
        XCTAssertThrowsError(try ControlCommandLine.parse(["ls", "--bogus"], caller: nil))
        XCTAssertThrowsError(try ControlCommandLine.parse(["-p"], caller: nil))
        XCTAssertEqual(try ControlCommandLine.parse([], caller: nil), .help)
        XCTAssertEqual(try ControlCommandLine.parse(["--version"], caller: nil), .version)
    }
}

final class PaneTargetTests: XCTestCase {
    private let panes = [
        PaneTarget.Candidate(id: "AAAA-1111-BEEF", label: "server"),
        PaneTarget.Candidate(id: "BBBB-2222-BEEF", label: "Logs"),
        PaneTarget.Candidate(id: "CCCC-3333-CAFE", label: nil),
    ]

    func testFullIdThenLabelThenSuffix() {
        XCTAssertEqual(PaneTarget.resolve("aaaa-1111-beef", among: panes), .found("AAAA-1111-BEEF"))
        XCTAssertEqual(PaneTarget.resolve("logs", among: panes), .found("BBBB-2222-BEEF"))
        XCTAssertEqual(PaneTarget.resolve("cafe", among: panes), .found("CCCC-3333-CAFE"))
    }

    func testAmbiguousAndMissing() {
        XCTAssertEqual(PaneTarget.resolve("beef", among: panes), .ambiguous(["AAAA-1111-BEEF", "BBBB-2222-BEEF"]))
        XCTAssertEqual(PaneTarget.resolve("fe", among: panes), .missing)
        XCTAssertEqual(PaneTarget.resolve("nope", among: panes), .missing)
    }
}

final class ControlSocketTests: XCTestCase {
    func testARequestGetsItsAnswer() throws {
        let path = NSTemporaryDirectory() + "pc-\(getpid()).sock"
        let server = ControlServer(path: path) { request, reply in
            reply(.ok("got \(request.command) \(request.arguments.joined(separator: " "))", json: "{\"ok\":true}"))
        }
        try server.start()
        defer { server.stop() }
        let answered = expectation(description: "answer")
        DispatchQueue.global().async {
            let response = ControlClient.send(ControlRequest(command: "send", arguments: ["hi", "there"]), to: path)
            XCTAssertEqual(response, .ok("got send hi there", json: "{\"ok\":true}"))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
    }

    func testNobodyListeningIsUnreachable() {
        XCTAssertNil(ControlClient.send(ControlRequest(command: "ls"), to: NSTemporaryDirectory() + "nobody-\(getpid()).sock"))
    }
}
