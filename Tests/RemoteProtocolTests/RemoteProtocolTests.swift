import Foundation
import RemoteControl
import XCTest
@testable import RemoteProtocol

/// Every message the protocol defines, as it goes on the wire.
private enum Samples {
    static let command = RemoteCommand(id: "cmd:1", command: "make test", running: false, exitCode: 0, started: 1_792_850_000, finished: 1_792_850_012.5)
    static let workspace = RemoteWorkspace(
        windows: [RemoteWindow(id: "W1", key: true, selectedTab: "T1", tabs: [
            RemoteTab(id: "T1", title: "Remote API", project: "R1", pinned: false, focusedPane: "P1", panes: [
                RemotePane(id: "P1", title: "claude", folder: "/Users/me/promptty", program: "claude", state: .permission,
                           agent: RemoteAgent(tool: "Bash", since: 1_792_850_100), commands: [command]),
                RemotePane(id: "P2", label: "logs", title: "zsh", folder: "/Users/me/promptty", state: .failed, exitCode: 1, unseen: true,
                           ports: [3000], remote: "deploy@munin-01"),
            ]),
        ])],
        projects: [RemoteProject(id: "R1", name: "promptty", folded: false)])

    static func all() throws -> [(name: String, message: RemoteMessage)] {
        [
            ("hello", .request(try RemoteRequest(id: 1, method: RemoteProtocol.Method.hello,
                                                 params: Hello(client: "PrompTTY for iPhone 0.1")))),
            ("welcome", .response(try .result(Welcome(server: "PrompTTY 2.1", mac: "Mikkel's Mac Studio", user: "mikkel@example.com"), id: 1))),
            ("unsupported-version", .response(.error(RemoteError(code: RemoteError.unsupportedVersion, message: "PrompTTY speaks protocol 1; this client speaks 2",
                                                                data: .array([.int(1)])), id: 1))),
            ("control-send", .request(try RemoteRequest(id: "send-7", method: "send",
                                                        params: ControlParams(target: "tests", arguments: ["make test"], flags: ["enter", "json"])))),
            ("control-ls", .request(RemoteRequest(id: 2, method: "ls"))),
            ("control-response", .response(try .result(ControlResponse.ok("sent", json: #"{"cmd":"c1"}"#), id: "send-7"))),
            ("control-wait-exit", .response(try .result(ControlResponse(code: 2, text: "exited 2"), id: 3))),
            ("parse-error", .response(.error(RemoteError(code: RemoteError.parseError, message: "not JSON"), id: nil))),
            ("event", .notification(RemoteNotification(method: "example.changed", params: .object(["count": .int(3), "ok": .bool(true)])))),
            ("subscribe", .request(RemoteRequest(id: 4, method: RemoteProtocol.Method.subscribe))),
            ("workspace", .notification(try RemoteNotification(method: RemoteProtocol.Event.workspace, params: workspace))),
            ("command-finished", .notification(try RemoteNotification(method: RemoteProtocol.Event.commandFinished,
                                                                      params: CommandFinished(pane: "P1", tab: "T1", command: command)))),
            ("blocks", .request(try RemoteRequest(id: 5, method: RemoteProtocol.Method.blocks, params: BlocksParams(pane: "tests", limit: 5)))),
            ("blocks-result", .response(try .result(BlocksResult(pane: "P1", commands: [command]), id: 5))),
        ]
    }
}

final class RemoteMessageTests: XCTestCase {
    func testEveryMessageRoundTrips() throws {
        for (name, message) in try Samples.all() {
            XCTAssertEqual(try RemoteMessage.decode(message.encoded()), message, name)
        }
    }

    /// The wire format is pinned: a change to a message shows up as a change to its fixture.
    /// `PROMPTTY_RECORD_FIXTURES=1 swift test --filter RemoteProtocolTests` writes them again.
    func testEveryMessageMatchesItsFixture() throws {
        let record = ProcessInfo.processInfo.environment["PROMPTTY_RECORD_FIXTURES"] == "1"
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        for (name, message) in try Samples.all() {
            let text = String(decoding: try message.encoded(), as: UTF8.self)
            if record {
                try (text + "\n").write(to: folder.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
                continue
            }
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"), "no fixture for \(name)")
            let fixture = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines)
            XCTAssertEqual(text, fixture, name)
            XCTAssertEqual(try RemoteMessage.decode(Data(fixture.utf8)), message, name)
        }
    }

    func testTellsRequestsNotificationsAndResponsesApart() throws {
        XCTAssertEqual(try decode(#"{"jsonrpc":"2.0","id":4,"method":"ls"}"#), .request(RemoteRequest(id: 4, method: "ls")))
        XCTAssertEqual(try decode(#"{"jsonrpc":"2.0","method":"tick"}"#), .notification(RemoteNotification(method: "tick")))
        XCTAssertEqual(try decode(#"{"jsonrpc":"2.0","id":"a","result":null}"#), .response(RemoteResponse(id: "a", outcome: .result(.null))))
        XCTAssertThrowsError(try decode(#"{"jsonrpc":"1.0","id":4,"method":"ls"}"#))
        XCTAssertThrowsError(try decode(#"{"jsonrpc":"2.0","id":4}"#))
    }

    func testJSONValuesKeepTheirKinds() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"[true, 1, 1.5, "1", null, {"a": false}]"#.utf8))
        XCTAssertEqual(value, .array([.bool(true), .int(1), .double(1.5), .string("1"), .null, .object(["a": .bool(false)])]))
    }

    func testAResultReadsAsItsTypeAndAnErrorThrows() throws {
        let welcome = Welcome(server: "PrompTTY 2.1", mac: "Studio", user: "me")
        XCTAssertEqual(try RemoteResponse.result(welcome, id: 1).result(as: Welcome.self), welcome)
        let failure = RemoteResponse.error(RemoteError(code: RemoteError.notAllowed, message: "no"), id: 1)
        XCTAssertThrowsError(try failure.result(as: Welcome.self)) { XCTAssertEqual(($0 as? RemoteError)?.code, RemoteError.notAllowed) }
    }

    private func decode(_ text: String) throws -> RemoteMessage { try RemoteMessage.decode(Data(text.utf8)) }
}

final class RemoteMethodTests: XCTestCase {
    func testHelloIsAnsweredForASupportedVersionOnly() {
        let welcome = Welcome.answer(Hello(client: "phone"), server: "PrompTTY 2.1", mac: "Studio", user: "me")
        XCTAssertEqual(try? welcome.get().protocolVersion, RemoteProtocol.version)
        guard case .failure(let error) = Welcome.answer(Hello(protocolVersion: 99, client: "phone"), server: "", mac: "", user: "") else {
            return XCTFail("version 99 was accepted")
        }
        XCTAssertEqual(error.code, RemoteError.unsupportedVersion)
        XCTAssertEqual(error.data, .array(RemoteProtocol.supported.map(JSONValue.int)))
    }

    func testControlParamsBecomeTheControlSocketsRequest() throws {
        let request = RemoteRequest(id: 1, method: "split", params: .object(["arguments": .array([.string("right")]), "options": .object(["label": .string("tests")])]))
        let params = try request.params(as: ControlParams.self)
        XCTAssertEqual(params.request(command: request.method),
                       ControlRequest(command: "split", caller: nil, target: nil, arguments: ["right"], flags: [], options: ["label": "tests"]))
        XCTAssertEqual(try RemoteRequest(id: 2, method: "ls").params(as: ControlParams.self), ControlParams())
    }

    func testEveryControlCommandIsAMethod() {
        XCTAssertTrue(RemoteProtocol.controlMethods.isSuperset(of: ["ls", "send", "capture", "split", "new-tab", "wait"]))
        XCTAssertFalse(RemoteProtocol.controlMethods.contains(RemoteProtocol.Method.hello))
    }
}
