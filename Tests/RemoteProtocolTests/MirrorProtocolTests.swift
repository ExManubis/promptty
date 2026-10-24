import Foundation
import XCTest
@testable import RemoteProtocol

/// Mirroring's messages, as they go on the wire (beside `RemoteMessageTests`' samples, pinned the
/// same way: `PROMPTTY_RECORD_FIXTURES=1 swift test --filter RemoteProtocolTests` writes them).
private enum MirrorSamples {
    static let state = MirrorState(pane: "P1", cols: 120, rows: 40, seq: 5120, typing: true)
    static let position = MirrorPosition(stream: "6F1C0D2E-0000-4000-8000-000000000001", seq: 5120)

    static func all() throws -> [(name: String, message: RemoteMessage)] {
        [
            ("mirror-attach", .request(try RemoteRequest(id: 10, method: RemoteProtocol.Method.attach,
                                                         params: AttachParams(pane: "claude", scrollback: 500)))),
            ("mirror-attached", .response(try .result(Attached(pane: "P1", position: position,
                                                               snapshot: Data("\u{1b}c$ ls\r\nREADME.md\r\n\u{1b}[?2004h\u{1b}[3;3H".utf8), state: state), id: 10))),
            ("mirror-attach-resume", .request(try RemoteRequest(id: 11, method: RemoteProtocol.Method.attach,
                                                                params: AttachParams(pane: "P1", resume: position)))),
            ("mirror-attached-resumed", .response(try .result(Attached(pane: "P1", position: position, snapshot: nil, state: state), id: 11))),
            ("mirror-history", .request(try RemoteRequest(id: 19, method: RemoteProtocol.Method.history,
                                                          params: HistoryParams(pane: "P1", scrollback: 2000)))),
            ("mirror-history-taken", .response(try .result(History(pane: "P1", position: position, snapshot: Data("\u{1b}cone\r\ntwo\r\n".utf8),
                                                                   cols: 120, rows: 40), id: 19))),
            ("mirror-output", .notification(try RemoteNotification(method: RemoteProtocol.Event.output,
                                                                    params: MirrorOutput(pane: "P1", stream: position.stream, seq: 5120,
                                                                                         data: Data("\u{1b}[1;32m✓\u{1b}[0m done\r\n".utf8))))),
            ("mirror-input-text", .request(try RemoteRequest(id: 12, method: RemoteProtocol.Method.input, params: InputParams(pane: "P1", text: "ls -la\r")))),
            ("mirror-input-paste", .request(try RemoteRequest(id: 13, method: RemoteProtocol.Method.input, params: InputParams(pane: "P1", paste: "line one\nline two")))),
            ("mirror-input-key", .request(try RemoteRequest(id: 14, method: RemoteProtocol.Method.input,
                                                            params: InputParams(pane: "P1", key: RemoteKey("c", mods: [.ctrl]))))),
            ("mirror-input-ok", .response(.init(id: 14, outcome: .result(.object([:]))))),
            ("mirror-typing-off", .response(.error(RemoteError(code: RemoteError.typingOff, message: "typing from other devices is off on the Mac"), id: 12))),
            ("mirror-attach-sized", .request(try RemoteRequest(id: 15, method: RemoteProtocol.Method.attach,
                                                               params: AttachParams(pane: "P1", cols: 48, rows: 22)))),
            ("mirror-resize", .request(try RemoteRequest(id: 16, method: RemoteProtocol.Method.resize, params: GridParams(pane: "P1", cols: 100, rows: 18)))),
            ("mirror-sized", .response(try .result(MirrorState(pane: "P1", cols: 100, rows: 18, seq: 6000, sizedBy: "Mikkel's iPhone",
                                                               sizedByMe: true, typing: true), id: 16))),
            ("mirror-not-attached", .response(.error(RemoteError(code: RemoteError.notAttached, message: "attach to P2 first"), id: 17))),
            ("mirror-pane-state", .notification(try RemoteNotification(method: RemoteProtocol.Event.paneState,
                                                                        params: MirrorState(pane: "P1", cols: 120, rows: 40, seq: 7000,
                                                                                            password: true, typing: true)))),
            ("mirror-detach", .request(try RemoteRequest(id: 18, method: RemoteProtocol.Method.detach, params: PaneParams(pane: "P1")))),
            ("mirror-detached", .notification(try RemoteNotification(method: RemoteProtocol.Event.detached, params: Detached(pane: "P1", reason: .behind)))),
        ]
    }
}

final class MirrorProtocolTests: XCTestCase {
    func testEveryMirrorMessageRoundTripsAndMatchesItsFixture() throws {
        let record = ProcessInfo.processInfo.environment["PROMPTTY_RECORD_FIXTURES"] == "1"
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        for (name, message) in try MirrorSamples.all() {
            XCTAssertEqual(try RemoteMessage.decode(message.encoded()), message, name)
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

    /// Bytes go as base64, whatever they are: escape sequences, UTF-8 cut in two, invalid UTF-8.
    func testOutputCarriesAnyBytes() throws {
        let bytes = Data([0x1b, 0x5b, 0x31, 0x6d, 0xc3, 0x00, 0xff, 0xfe])
        let event = try RemoteNotification(method: RemoteProtocol.Event.output, params: MirrorOutput(pane: "P", stream: "S", seq: 0, data: bytes))
        let decoded = try RemoteMessage.decode(RemoteMessage.notification(event).encoded())
        guard case .notification(let back) = decoded else { return XCTFail("not a notification") }
        XCTAssertEqual(try back.params(as: MirrorOutput.self).data, bytes)
        XCTAssertEqual(event.params?.objectValueForTest?["data"], .string(bytes.base64EncodedString()))
    }

    func testAKeyWithoutModsLeavesThemOutAndReadsBackEmpty() throws {
        let value = try JSONValue(encoding: RemoteKey("enter"))
        XCTAssertEqual(value, .object(["key": .string("enter")]))
        XCTAssertEqual(try value.decode(RemoteKey.self).mods, [])
        XCTAssertTrue(RemoteKey("pageDown").isValid)
        XCTAssertTrue(RemoteKey("x", mods: [.ctrl]).isValid)
        XCTAssertFalse(RemoteKey("hyper").isValid)
    }

    func testAttachedSaysWhetherItResumed() {
        let state = MirrorState(pane: "P", cols: 80, rows: 24, seq: 0)
        XCTAssertTrue(Attached(pane: "P", position: MirrorPosition(stream: "S", seq: 0), snapshot: nil, state: state).resumed)
        XCTAssertFalse(Attached(pane: "P", position: MirrorPosition(stream: "S", seq: 0), snapshot: Data(), state: state).resumed)
    }
}

private extension JSONValue {
    var objectValueForTest: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
