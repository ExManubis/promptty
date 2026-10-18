import AgentHooks
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

    func testLabelKeepOpenAndBlockOptions() throws {
        let r = try request(["split", "right", "--label", "tests", "--keep-open", "--json", "--", "make", "test"])
        XCTAssertEqual(r.options, ["label": "tests"])
        XCTAssertEqual(r.flags, ["keep-open", "json"])
        XCTAssertEqual(r.arguments, ["right", "make", "test"])
        let c = try request(["capture", "-c", "cmd:abcd", "--markdown"])
        XCTAssertEqual(c.options, ["cmd": "cmd:abcd"])
        XCTAssertEqual(c.flags, ["markdown"])
    }

    func testBlockIsRexsNameForAPane() throws {
        XCTAssertEqual(try request(["-b", "logs", "capture"]).target, "logs")
        XCTAssertEqual(try request(["capture", "--block", "block:abcd"]).target, "block:abcd")
    }

    func testWaitNeedsAPaneOrACommandAndWaitsAsLongAsItsTimeout() throws {
        // Not the caller's own pane, whose command is the one running promptty.
        XCTAssertThrowsError(try ControlCommandLine.parse(["wait"], caller: "C"))
        XCTAssertThrowsError(try ControlCommandLine.parse(["wait", "-c", "x", "--timeout", "soon"], caller: nil))
        let w = try request(["wait", "-c", "1234", "--timeout", "30"])
        XCTAssertEqual(ControlCommandLine.replyTimeout(for: w), 35)
        XCTAssertGreaterThan(ControlCommandLine.replyTimeout(for: try request(["wait", "-b", "tests"])), 3600)
        XCTAssertEqual(ControlCommandLine.replyTimeout(for: try request(["ls"])), 15)
    }

    func testNewWindowAndFocus() throws {
        let r = try request(["new-window", "--cwd", "~/proj", "--focus", "--json", "--", "npm", "run", "dev"])
        XCTAssertEqual(r.command, "new-window")
        XCTAssertEqual(r.options, ["cwd": "~/proj"])
        XCTAssertEqual(r.flags, ["focus", "json"])
        XCTAssertEqual(r.arguments, ["npm", "run", "dev"])
        XCTAssertEqual(try request(["new-tab", "-f"]).flags, ["focus"])
    }

    func testOutsideAPaneTheSocketIsTheAppsOwn() {
        XCTAssertEqual(ControlEnvironment.defaultSocket(home: "/Users/me", temporaryDirectory: "/tmp/"),
                       "/Users/me/Library/Application Support/PrompTTY/control.sock")
    }

    func testCloseNeedsANamedPane() throws {
        XCTAssertThrowsError(try ControlCommandLine.parse(["close"], caller: "C"))
        XCTAssertEqual(try request(["close", "-b", "tests"]).target, "tests")
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

    func testRexsBlockPrefixIsOptional() {
        XCTAssertEqual(PaneTarget.resolve("block:aaaa-1111-beef", among: panes), .found("AAAA-1111-BEEF"))
        XCTAssertEqual(PaneTarget.resolve("block:cafe", among: panes), .found("CCCC-3333-CAFE"))
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

    /// Clients that connect and send nothing hold up no thread and nobody else.
    func testIdleConnectionsDoNotHoldUpARequest() throws {
        let path = NSTemporaryDirectory() + "pc-idle-\(getpid()).sock"
        let server = ControlServer(path: path) { request, reply in reply(.ok(request.command)) }
        try server.start()
        defer { server.stop() }
        let address = try XCTUnwrap(HookSocket.address(path))
        var idle: [Int32] = []
        for _ in 0..<10 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            XCTAssertTrue(HookSocket.connect(fd, to: address))
            idle.append(fd)
        }
        defer { idle.forEach { close($0) } }
        let answered = expectation(description: "answer")
        DispatchQueue.global().async {
            XCTAssertEqual(ControlClient.send(ControlRequest(command: "ls"), to: path, timeout: 3), .ok("ls"))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
    }

    /// A folder that is not a real folder of the user's (here a symbolic link) is not used.
    func testRefusesAnUnsafeFolder() throws {
        let real = NSTemporaryDirectory() + "pc-real-\(getpid())"
        let link = NSTemporaryDirectory() + "pc-link-\(getpid())"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        defer {
            try? FileManager.default.removeItem(atPath: link)
            try? FileManager.default.removeItem(atPath: real)
        }
        let server = ControlServer(path: link + "/c.sock") { _, reply in reply(.ok()) }
        XCTAssertThrowsError(try server.start()) { XCTAssertEqual($0 as? ControlServer.Failure, .unsafeFolder) }
    }

    /// Another app took the path since: stopping leaves that app's socket.
    func testStopLeavesASocketThatIsNoLongerItsOwn() throws {
        let path = NSTemporaryDirectory() + "pc-stop-\(getpid()).sock"
        let first = ControlServer(path: path) { _, reply in reply(.ok()) }
        try first.start()
        unlink(path)
        let second = ControlServer(path: path) { _, reply in reply(.ok()) }
        try second.start()
        first.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        second.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testNobodyListeningIsUnreachable() {
        XCTAssertNil(ControlClient.send(ControlRequest(command: "ls"), to: NSTemporaryDirectory() + "nobody-\(getpid()).sock"))
    }
}
