import AgentHooks
import XCTest

final class HookMessageTests: XCTestCase {
    private let pane = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private func line(_ json: String) -> Data { Data(json.utf8) }

    func testParsesAMessage() throws {
        let message = try XCTUnwrap(HookMessage.parse(line(#"""
        {"pane":"6F9619FF-8B86-D011-B42D-00C04FC964FF","event":"PreToolUse","payload":{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","hook_event_name":"PreToolUse","tool_name":"Bash"}}
        """#)))
        XCTAssertEqual(message.pane, pane)
        XCTAssertEqual(message.event, .preToolUse)
        XCTAssertEqual(message.payload.sessionID, "s1")
        XCTAssertEqual(message.payload.transcriptPath, "/t.jsonl")
        XCTAssertEqual(message.payload.cwd, "/w")
        XCTAssertEqual(message.payload.toolName, "Bash")
    }

    func testTheEventFallsBackToThePayloadsEventName() {
        let message = HookMessage.parse(line(#"{"pane":"6F9619FF-8B86-D011-B42D-00C04FC964FF","payload":{"hook_event_name":"Stop"}}"#))
        XCTAssertEqual(message?.event, .stop)
    }

    func testAMissingPayloadIsEmpty() {
        let message = HookMessage.parse(line(#"{"pane":"6F9619FF-8B86-D011-B42D-00C04FC964FF","event":"Stop"}"#))
        XCTAssertEqual(message?.event, .stop)
        XCTAssertEqual(message?.payload, HookPayload())
    }

    func testMalformedMessagesAreIgnored() {
        for bad in [
            "",
            "not json",
            "[1,2]",
            #"{"event":"Stop"}"#,                                                   // no pane
            #"{"pane":"nope","event":"Stop"}"#,                                     // not a UUID
            #"{"pane":"6F9619FF-8B86-D011-B42D-00C04FC964FF","event":"Bogus"}"#,     // unknown event
            #"{"pane":"6F9619FF-8B86-D011-B42D-00C04FC964FF","event":3}"#,
            #"{"pane":"6F9619FF-8B86-D011-B42D-00C04FC964FF","event":"Stop","payload":"x"}"#,
        ] {
            XCTAssertNil(HookMessage.parse(line(bad)), bad)
        }
    }

    func testFieldsOfTheWrongTypeAreDropped() {
        let message = HookMessage.parse(line(#"{"pane":"6F9619FF-8B86-D011-B42D-00C04FC964FF","event":"PreToolUse","payload":{"tool_name":5,"session_id":"s"}}"#))
        XCTAssertNil(message?.payload.toolName)
        XCTAssertEqual(message?.payload.sessionID, "s")
    }

    func testLineWrapsTheHookInputForTheApp() throws {
        let input = Data(#"""
        {
          "session_id": "s1",
          "hook_event_name": "Notification",
          "message": "Claude needs your permission to use Bash",
          "prompt": "a secret\nprompt",
          "tool_input": {"command": "rm -rf build"}
        }
        """#.utf8)
        let data = try XCTUnwrap(HookMessage.line(pane: pane, event: "Notification", input: input))
        // One line, ending in a newline.
        XCTAssertEqual(data.last, UInt8(ascii: "\n"))
        XCTAssertEqual(data.filter { $0 == UInt8(ascii: "\n") }.count, 1)
        let message = try XCTUnwrap(HookMessage.parse(data.dropLast()))
        XCTAssertEqual(message.pane, pane)
        XCTAssertEqual(message.event, .notification)
        XCTAssertEqual(message.payload.message, "Claude needs your permission to use Bash")
        // Only what PrompTTY uses goes to the app: no prompts, no tool input.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("rm -rf"))
    }

    func testLineWithInputThatIsNotJSONStillSendsTheEvent() throws {
        let data = try XCTUnwrap(HookMessage.line(pane: pane, event: "Stop", input: Data("garbage".utf8)))
        XCTAssertEqual(HookMessage.parse(data)?.event, .stop)
    }

    func testCodexNotifyPayload() throws {
        let input = Data(#"{"type":"agent-turn-complete","turn-id":"1","last-assistant-message":"Done."}"#.utf8)
        let data = try XCTUnwrap(HookMessage.line(pane: pane, event: "codex-notify", input: input))
        let message = try XCTUnwrap(HookMessage.parse(data))
        XCTAssertEqual(message.event, .codexNotify)
        XCTAssertEqual(message.payload.type, "agent-turn-complete")
    }

    func testNotificationKinds() {
        func kind(_ message: String?, type: String? = nil) -> HookPayload.NotificationKind {
            HookPayload(message: message, notificationType: type).notificationKind
        }
        XCTAssertEqual(kind("Claude needs your permission to use Bash"), .permission)
        XCTAssertEqual(kind("Claude is waiting for your input"), .input)
        XCTAssertEqual(kind(nil), .input)
        XCTAssertEqual(kind("Something else"), .input)
        // Newer versions say which in a field of its own, whatever the message.
        XCTAssertEqual(kind("Claude needs your attention", type: "permission_prompt"), .permission)
        XCTAssertEqual(kind("Claude needs your permission", type: "idle_prompt"), .input)
        XCTAssertEqual(kind("x", type: "elicitation_dialog"), .input)
        XCTAssertEqual(kind("Signed in", type: "auth_success"), .none)
    }

    func testEnvironment() {
        XCTAssertEqual(HookEnvironment.variables(pane: pane, socket: "/s.sock"),
                       ["PROMPTTY_PANE_ID": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "PROMPTTY_SOCKET": "/s.sock"])
    }

    func testSocketPathUnderTheDataFolder() {
        XCTAssertEqual(HookSocket.path(dataFolder: "/Users/me/Library/Application Support/PrompTTY", temporaryDirectory: "/var/folders/x/T/"),
                       "/Users/me/Library/Application Support/PrompTTY/hooks.sock")
    }

    func testALongDataFolderFallsBackToAShortPathKeyedByIt() {
        let long = "/Users/me/" + String(repeating: "deep/", count: 25)
        let a = HookSocket.path(dataFolder: long, temporaryDirectory: "/var/folders/x/T/")
        XCTAssertTrue(a.hasPrefix("/var/folders/x/T/promptty-"), a)
        XCTAssertTrue(a.hasSuffix(".sock"))
        XCTAssertLessThanOrEqual(a.utf8.count, HookSocket.maxPathBytes)
        // Stable for a folder, different for another.
        XCTAssertEqual(a, HookSocket.path(dataFolder: long, temporaryDirectory: "/var/folders/x/T/"))
        XCTAssertNotEqual(a, HookSocket.path(dataFolder: long + "x", temporaryDirectory: "/var/folders/x/T/"))
        // A temporary folder too long as well: /tmp, with the user's id.
        let b = HookSocket.path(dataFolder: long, temporaryDirectory: long, userID: 501)
        XCTAssertTrue(b.hasPrefix("/tmp/promptty-501-"), b)
        XCTAssertLessThanOrEqual(b.utf8.count, HookSocket.maxPathBytes)
    }
}
