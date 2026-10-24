import Foundation
import RemoteProtocol
import Synchronization
import XCTest
@testable import RemoteServer

/// A terminal for the hub: output it is told to print, numbered; a snapshot of the bytes so far.
@MainActor
private final class FakePane: MirrorPane {
    private final class Handler: Sendable {
        let current = Mutex<(@Sendable (MirrorChunk) -> Void)?>(nil)
    }
    private let handler = Handler()
    var stream = "S1"
    var printed = Data()
    var grid: (cols: Int, rows: Int)? = (120, 40)
    var macGrid = (cols: 120, rows: 40)
    var password = false
    var inputs: [InputParams] = []
    var subscriptions = 0

    final class Subscription {
        let onEnd: () -> Void
        init(onEnd: @escaping () -> Void) { self.onEnd = onEnd }
        deinit { onEnd() }
    }

    func subscribe(_ handler: @escaping @Sendable (MirrorChunk) -> Void) -> AnyObject {
        self.handler.current.withLock { $0 = handler }
        subscriptions += 1
        return Subscription { [handler = self.handler] in handler.current.withLock { $0 = nil } }
    }

    func snapshot(scrollback: Int) -> MirrorSnapshot? {
        guard let grid else { return nil }
        return MirrorSnapshot(vt: Data("SNAP:".utf8) + printed, cols: grid.cols, rows: grid.rows, position: MirrorPosition(stream: stream, seq: printed.count))
    }

    var seq: Int { printed.count }

    func input(_ params: InputParams) -> Bool {
        if let key = params.key, !key.isValid { return false }
        inputs.append(params)
        return true
    }

    func setControlledGrid(_ grid: (cols: Int, rows: Int)?) {
        self.grid = grid ?? macGrid
    }

    /// The program prints: the chunk goes to the subscriber.
    func print(_ text: String) { print(Data(text.utf8)) }

    func print(_ data: Data) {
        let chunk = MirrorChunk(stream: stream, offset: printed.count, data: data)
        printed.append(data)
        handler.current.withLock { $0 }?(chunk)
    }
}

/// What the hub sends each client.
private final class Sent: Sendable {
    private let events = Mutex<[(UUID, RemoteNotification)]>([])

    func add(_ client: UUID, _ event: RemoteNotification) { events.withLock { $0.append((client, event)) } }

    func events(to client: UUID, _ method: String? = nil) -> [RemoteNotification] {
        events.withLock { $0 }.filter { $0.0 == client && (method == nil || $0.1.method == method) }.map(\.1)
    }

    func output(to client: UUID) -> [MirrorOutput] {
        events(to: client, RemoteProtocol.Event.output).compactMap { try? $0.params(as: MirrorOutput.self) }
    }

    func clear() { events.withLock { $0.removeAll() } }
}

final class MirrorFeedTests: XCTestCase {
    private let client = UUID()

    private func outputs(_ events: [RemoteNotification]?) -> [MirrorOutput] {
        (events ?? []).compactMap { try? $0.params(as: MirrorOutput.self) }
    }

    func testAClientGetsTheBytesAfterItsSnapshotOnlyAndInOrder() {
        let sent = Sent()
        let feed = MirrorFeed(pane: "P") { sent.add($0, $1) }
        feed.receive(MirrorChunk(stream: "S", offset: 0, data: Data("hello ".utf8)))
        feed.receive(MirrorChunk(stream: "S", offset: 6, data: Data("world".utf8)))
        // The snapshot was taken at 8 ("hello wo"): "rld" is what the client lacks.
        let backlog = outputs(feed.activate(client, stream: "S", from: 8))
        XCTAssertEqual(backlog, [MirrorOutput(pane: "P", stream: "S", seq: 8, data: Data("rld".utf8))])
        feed.receive(MirrorChunk(stream: "S", offset: 11, data: Data("!".utf8)))
        XCTAssertEqual(sent.output(to: client), [MirrorOutput(pane: "P", stream: "S", seq: 11, data: Data("!".utf8))])
    }

    func testASnapshotAheadOfTheDeliveredOutputSkipsWhatItHolds() {
        let sent = Sent()
        let feed = MirrorFeed(pane: "P") { sent.add($0, $1) }
        // Taken at 5 before the chunk holding bytes 0..<9 was delivered.
        XCTAssertEqual(feed.activate(client, stream: "S", from: 5)?.count, 0)
        feed.receive(MirrorChunk(stream: "S", offset: 0, data: Data("123456789".utf8)))
        XCTAssertEqual(sent.output(to: client), [MirrorOutput(pane: "P", stream: "S", seq: 5, data: Data("6789".utf8))])
    }

    func testABigBacklogGoesInEventsOfAtMost64KiB() {
        let feed = MirrorFeed(pane: "P") { _, _ in }
        feed.receive(MirrorChunk(stream: "S", offset: 0, data: Data(repeating: 0x41, count: 150_000)))
        let backlog = outputs(feed.activate(client, stream: "S", from: 0))
        XCTAssertEqual(backlog.map(\.data.count), [65_536, 65_536, 18_928])
        XCTAssertEqual(backlog.map(\.seq), [0, 65_536, 131_072])
    }

    func testResumingNeedsTheSameStreamAndBytesStillKept() {
        let feed = MirrorFeed(pane: "P") { _, _ in }
        feed.receive(MirrorChunk(stream: "S", offset: 0, data: Data(repeating: 0x41, count: MirrorFeed.capacity + 10)))
        XCTAssertTrue(feed.canResume(from: MirrorPosition(stream: "S", seq: MirrorFeed.capacity)))
        XCTAssertFalse(feed.canResume(from: MirrorPosition(stream: "S", seq: 5)), "fell out of the buffer")
        XCTAssertFalse(feed.canResume(from: MirrorPosition(stream: "T", seq: MirrorFeed.capacity)), "another stream")
        XCTAssertNil(feed.activate(client, stream: "S", from: 5))
        // The output started over (the terminal lost its subscribers): nothing goes on from before.
        feed.receive(MirrorChunk(stream: "T", offset: 0, data: Data("new".utf8)))
        XCTAssertFalse(feed.canResume(from: MirrorPosition(stream: "S", seq: MirrorFeed.capacity + 10)))
        XCTAssertTrue(feed.canResume(from: MirrorPosition(stream: "T", seq: 3)))
    }
}

@MainActor
final class MirrorHubTests: XCTestCase {
    private let phone = MirrorClient(id: UUID(), name: "iPhone")
    private let pad = MirrorClient(id: UUID(), name: "iPad")
    private var pane: FakePane!
    private var hub: MirrorHub!
    private var sent: Sent!

    override func setUp() async throws {
        let pane = FakePane()
        self.pane = pane
        hub = MirrorHub(typing: false) { name in
            name == "P" || name == "claude" ? .success(("P", pane)) : .failure(RemoteError(code: RemoteError.invalidParams, message: "no pane \(name)"))
        }
        let sent = Sent()
        self.sent = sent
        hub.outbox.connect { sent.add($0, $1) }
    }

    /// Attaches as the server does: the answer, then the client goes live.
    private func attach(_ client: MirrorClient, _ params: AttachParams = AttachParams(pane: "claude")) throws -> (Attached, [MirrorOutput]) {
        let reply = hub.handle(.attach(params), from: client)
        let attached = try reply.result.get().decode(Attached.self)
        let backlog = try XCTUnwrap(reply.activate?()).compactMap { try? $0.params(as: MirrorOutput.self) }
        return (attached, backlog)
    }

    private func error(_ call: MirrorCall, from client: MirrorClient) -> Int? {
        guard case .failure(let error) = hub.handle(call, from: client).result else { return nil }
        return error.code
    }

    func testAttachingGivesTheSnapshotThenTheOutputAfterIt() throws {
        pane.print("$ ls\r\n")
        let (attached, backlog) = try attach(phone)
        XCTAssertEqual(attached.pane, "P")
        XCTAssertEqual(attached.snapshot, Data("SNAP:$ ls\r\n".utf8))
        XCTAssertEqual(attached.position, MirrorPosition(stream: "S1", seq: 6))
        XCTAssertEqual(attached.state, MirrorState(pane: "P", cols: 120, rows: 40, seq: 6))
        XCTAssertEqual(backlog, [])
        pane.print("README.md\r\n")
        pane.print("$ ")
        let output = sent.output(to: phone.id)
        XCTAssertEqual(output.map(\.seq), [6, 17])
        XCTAssertEqual(output.reduce(Data()) { $0 + $1.data }, Data("README.md\r\n$ ".utf8))
        XCTAssertEqual(hub.attachments["P"]?.viewers, ["iPhone"])
    }

    func testAnUnknownPaneIsAnErrorAndNothingElseWorksBeforeAttaching() {
        XCTAssertEqual(error(.attach(AttachParams(pane: "nope")), from: phone), RemoteError.invalidParams)
        XCTAssertEqual(error(.input(InputParams(pane: "P", text: "x")), from: phone), RemoteError.notAttached)
        XCTAssertEqual(error(.takeControl(ControlTake(pane: "P", cols: 40, rows: 20)), from: phone), RemoteError.notAttached)
    }

    func testTypingNeedsTheSetting() throws {
        _ = try attach(phone)
        XCTAssertEqual(error(.input(InputParams(pane: "P", text: "ls\r")), from: phone), RemoteError.typingOff)
        hub.typing = true
        // Attached clients are told typing is allowed now.
        XCTAssertEqual(try sent.events(to: phone.id, RemoteProtocol.Event.paneState).last?.params(as: MirrorState.self).typing, true)
        XCTAssertNil(error(.input(InputParams(pane: "P", text: "ls\r")), from: phone))
        XCTAssertNil(error(.input(InputParams(pane: "claude", key: RemoteKey("c", mods: [.ctrl]))), from: phone))
        XCTAssertEqual(error(.input(InputParams(pane: "P", key: RemoteKey("hyper"))), from: phone), RemoteError.invalidParams)
        XCTAssertEqual(pane.inputs, [InputParams(pane: "P", text: "ls\r"), InputParams(pane: "claude", key: RemoteKey("c", mods: [.ctrl]))])
    }

    func testOneClientHasControlAtATimeAndLettingGoRestoresTheMacsSize() throws {
        _ = try attach(phone)
        _ = try attach(pad)
        let taken = try hub.handle(.takeControl(ControlTake(pane: "P", cols: 48, rows: 22)), from: phone).result.get().decode(MirrorState.self)
        XCTAssertEqual(taken.cols, 48)
        XCTAssertEqual(taken.rows, 22)
        XCTAssertTrue(taken.inControl)
        XCTAssertEqual(taken.controller, "iPhone")
        XCTAssertEqual(hub.attachments["P"]?.controller, "iPhone")
        // The iPad is told who has control, and the size.
        let padState = try XCTUnwrap(sent.events(to: pad.id, RemoteProtocol.Event.paneState).last?.params(as: MirrorState.self))
        XCTAssertEqual(padState.controller, "iPhone")
        XCTAssertFalse(padState.inControl)
        XCTAssertEqual(padState.cols, 48)
        // Only the controller resizes.
        XCTAssertEqual(error(.resize(ControlTake(pane: "P", cols: 30, rows: 10)), from: pad), RemoteError.notInControl)
        XCTAssertNil(error(.resize(ControlTake(pane: "P", cols: 100, rows: 18)), from: phone))
        XCTAssertEqual(pane.grid?.cols, 100)
        // The iPad takes it: the iPhone loses it.
        XCTAssertNil(error(.takeControl(ControlTake(pane: "P", cols: 80, rows: 30)), from: pad))
        let phoneState = try XCTUnwrap(sent.events(to: phone.id, RemoteProtocol.Event.paneState).last?.params(as: MirrorState.self))
        XCTAssertEqual(phoneState.controller, "iPad")
        XCTAssertFalse(phoneState.inControl)
        // Releasing someone else's control does nothing; the controller's own restores the Mac's size.
        _ = hub.handle(.releaseControl(PaneParams(pane: "P")), from: phone)
        XCTAssertEqual(pane.grid?.cols, 80)
        _ = hub.handle(.releaseControl(PaneParams(pane: "P")), from: pad)
        XCTAssertEqual(pane.grid?.cols, 120)
        XCTAssertNil(hub.attachments["P"]?.controller)
    }

    func testAControllerThatDisconnectsGivesTheSizeBack() throws {
        _ = try attach(phone)
        _ = hub.handle(.takeControl(ControlTake(pane: "P", cols: 48, rows: 22)), from: phone)
        XCTAssertEqual(pane.grid?.cols, 48)
        hub.clientGone(phone.id)
        XCTAssertEqual(pane.grid?.cols, 120)
        XCTAssertNil(hub.attachments["P"])
    }

    func testAPasswordPromptIsTold() throws {
        _ = try attach(phone)
        pane.password = true
        hub.paneChanged("P")
        XCTAssertEqual(try sent.events(to: phone.id, RemoteProtocol.Event.paneState).last?.params(as: MirrorState.self).password, true)
        // Nothing changed: nothing more is sent.
        let count = sent.events(to: phone.id).count
        hub.paneChanged("P")
        XCTAssertEqual(sent.events(to: phone.id).count, count)
    }

    func testAClientThatComesBackResumesWithoutASnapshot() throws {
        pane.print("one\r\n")
        let (attached, _) = try attach(phone)
        pane.print("two\r\n")
        hub.clientGone(phone.id)
        pane.print("three\r\n")
        // Kept after the last client went: it gets what it missed.
        let (resumed, backlog) = try attach(phone, AttachParams(pane: "P", resume: MirrorPosition(stream: "S1", seq: attached.position.seq + 5)))
        XCTAssertTrue(resumed.resumed)
        XCTAssertEqual(backlog.reduce(Data()) { $0 + $1.data }, Data("three\r\n".utf8))
        XCTAssertEqual(pane.subscriptions, 1)
        // From somewhere it never was (another stream): a snapshot.
        let (fresh, _) = try attach(pad, AttachParams(pane: "P", resume: MirrorPosition(stream: "S0", seq: 3)))
        XCTAssertFalse(fresh.resumed)
    }

    func testAClosedPaneDetachesItsClients() throws {
        _ = try attach(phone)
        hub.paneClosed("P")
        XCTAssertEqual(try sent.events(to: phone.id, RemoteProtocol.Event.detached).last?.params(as: Detached.self), Detached(pane: "P", reason: .closed))
        XCTAssertNil(hub.attachments["P"])
    }
}

final class MirrorSessionTests: XCTestCase {
    func testMirrorMethodsBecomeMirrorCalls() throws {
        var session = RemoteSession(server: "s", mac: "m", user: "u")
        _ = session.receive(try RemoteMessage.request(try RemoteRequest(id: 1, method: "hello", params: Hello(client: "phone"))).encoded())
        let attach = try RemoteRequest(id: 2, method: RemoteProtocol.Method.attach, params: AttachParams(pane: "P"))
        XCTAssertEqual(session.receive(try RemoteMessage.request(attach).encoded()), [.mirror(.attach(AttachParams(pane: "P")), id: 2)])
        let take = try RemoteRequest(id: 3, method: RemoteProtocol.Method.takeControl, params: ControlTake(pane: "P", cols: 40, rows: 20))
        XCTAssertEqual(session.receive(try RemoteMessage.request(take).encoded()), [.mirror(.takeControl(ControlTake(pane: "P", cols: 40, rows: 20)), id: 3)])
        let bad = RemoteRequest(id: 4, method: RemoteProtocol.Method.input, params: .object(["text": .string("x")]))
        guard case .send(.response(let response)) = session.receive(try RemoteMessage.request(bad).encoded()).first,
              case .error(let error) = response.outcome else { return XCTFail("input without a pane was taken") }
        XCTAssertEqual(error.code, RemoteError.invalidParams)
    }
}

/// Over the network: a client attaches, gets the snapshot, then the output; types; takes control.
final class MirrorServerTests: XCTestCase {
    func testAClientMirrorsAPaneOverTheNetwork() async throws {
        let (hub, pane) = await MainActor.run { () -> (MirrorHub, FakePane) in
            let pane = FakePane()
            pane.print("before\r\n")
            return (MirrorHub(typing: true) { _ in .success(("P", pane)) }, pane)
        }
        let port = UInt16.random(in: 40_000...60_000)
        let server = RemoteServer(host: "127.0.0.1", port: port, owner: 7, server: "test", mac: "Mac",
                                  identify: { _ in TailnetIdentity.Caller(userID: 7, login: "me") },
                                  handler: { _, reply in reply(.ok()) }, mirror: hub, onClients: { _ in })
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        _ = try await exchange(task, .request(try RemoteRequest(id: 1, method: "hello", params: Hello(client: "phone"))))
        guard case .response(let response) = try await exchange(task, .request(try RemoteRequest(id: 2, method: RemoteProtocol.Method.attach,
                                                                                                    params: AttachParams(pane: "P")))) else { return XCTFail() }
        let attached = try response.result(as: Attached.self)
        XCTAssertEqual(attached.snapshot, Data("SNAP:before\r\n".utf8))
        XCTAssertEqual(attached.position.seq, 8)

        await MainActor.run { pane.print("after\r\n") }
        guard case .notification(let event) = try await receive(task) else { return XCTFail() }
        XCTAssertEqual(try event.params(as: MirrorOutput.self), MirrorOutput(pane: "P", stream: "S1", seq: 8, data: Data("after\r\n".utf8)))

        guard case .response(let typed) = try await exchange(task, .request(try RemoteRequest(id: 3, method: RemoteProtocol.Method.input,
                                                                                                params: InputParams(pane: "P", text: "ls\r")))) else { return XCTFail() }
        XCTAssertEqual(typed.id, 3)
        let inputs = await MainActor.run { pane.inputs }
        XCTAssertEqual(inputs, [InputParams(pane: "P", text: "ls\r")])

        guard case .response(let took) = try await exchange(task, .request(try RemoteRequest(id: 4, method: RemoteProtocol.Method.takeControl,
                                                                                               params: ControlTake(pane: "P", cols: 50, rows: 20)))) else { return XCTFail() }
        XCTAssertEqual(try took.result(as: MirrorState.self).cols, 50)
        let attachments = await MainActor.run { hub.attachments["P"]?.controller }
        XCTAssertEqual(attachments, "phone")

        // Hanging up gives the size back.
        task.cancel(with: .goingAway, reason: nil)
        let deadline = Date().addingTimeInterval(5)
        while await MainActor.run(body: { pane.grid?.cols }) != 120, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let cols = await MainActor.run { pane.grid?.cols }
        XCTAssertEqual(cols, 120)
    }

    private func exchange(_ task: URLSessionWebSocketTask, _ message: RemoteMessage) async throws -> RemoteMessage {
        try await task.send(.string(String(decoding: message.encoded(), as: UTF8.self)))
        return try await receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) async throws -> RemoteMessage {
        guard case .string(let text) = try await task.receive() else { throw URLError(.cannotParseResponse) }
        return try RemoteMessage.decode(Data(text.utf8))
    }
}
