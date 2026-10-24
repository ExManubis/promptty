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

    func setClientGrid(_ grid: (cols: Int, rows: Int)?) {
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
    private let sent = Mutex<[(UUID, MirrorEvent)]>([])

    func add(_ client: UUID, _ event: MirrorEvent) { sent.withLock { $0.append((client, event)) } }
    func add(_ client: UUID, _ output: MirrorOutput) { add(client, .output(output)) }

    func events(to client: UUID, _ method: String? = nil) -> [RemoteNotification] {
        sent.withLock { $0 }.compactMap { entry -> RemoteNotification? in
            guard entry.0 == client, case .event(let event) = entry.1, method == nil || event.method == method else { return nil }
            return event
        }
    }

    func output(to client: UUID) -> [MirrorOutput] {
        sent.withLock { $0 }.compactMap { entry -> MirrorOutput? in
            guard entry.0 == client, case .output(let output) = entry.1 else { return nil }
            return output
        }
    }

    func count(to client: UUID) -> Int { sent.withLock { $0 }.filter { $0.0 == client }.count }

    func clear() { sent.withLock { $0.removeAll() } }
}

final class MirrorFeedTests: XCTestCase {
    private let client = UUID()

    private func outputs(_ outputs: [MirrorOutput]?) -> [MirrorOutput] { outputs ?? [] }

    func testAClientGetsTheBytesAfterItsSnapshotOnlyAndInOrder() {
        let sent = Sent()
        let feed = MirrorFeed(pane: "P") { sent.add($0, $1 as MirrorOutput) }
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
        let feed = MirrorFeed(pane: "P") { sent.add($0, $1 as MirrorOutput) }
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
        hub.outbox.connect { sent.add($0, $1 as MirrorEvent) }
    }

    /// Attaches as the server does: the answer, then the client goes live.
    private func attach(_ client: MirrorClient, _ params: AttachParams = AttachParams(pane: "claude")) throws -> (Attached, [MirrorOutput]) {
        let reply = hub.handle(.attach(params), from: client)
        let attached = try reply.result.get().decode(Attached.self)
        let backlog = try XCTUnwrap(reply.activate?())
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
        XCTAssertEqual(error(.resize(GridParams(pane: "P", cols: 40, rows: 20)), from: phone), RemoteError.notAttached)
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

    func testTheDeviceUsedLastSizesThePane() throws {
        hub.typing = true
        _ = try attach(phone, AttachParams(pane: "P", cols: 48, rows: 22))
        // Opened on the phone: the pane has its grid.
        XCTAssertEqual(pane.grid?.cols, 48)
        XCTAssertEqual(hub.attachments["P"]?.sizedBy, "iPhone")
        // The iPad opens it: it has the iPad's grid, and the iPhone is told.
        _ = try attach(pad, AttachParams(pane: "P", cols: 80, rows: 30))
        XCTAssertEqual(pane.grid?.cols, 80)
        let phoneState = try XCTUnwrap(sent.events(to: phone.id, RemoteProtocol.Event.paneState).last?.params(as: MirrorState.self))
        XCTAssertEqual(phoneState.sizedBy, "iPad")
        XCTAssertFalse(phoneState.sizedByMe)
        // Typing on the iPhone gives it back its grid.
        XCTAssertNil(error(.input(InputParams(pane: "P", text: "x")), from: phone))
        XCTAssertEqual(pane.grid?.cols, 48)
        // The iPad turns: its new grid is kept, and the pane takes it, the iPad in use.
        XCTAssertNil(error(.resize(GridParams(pane: "P", cols: 100, rows: 18)), from: pad))
        XCTAssertEqual(pane.grid?.cols, 100)
        // Used on the Mac: the Mac's size, and both are told.
        hub.takeBack("P")
        XCTAssertEqual(pane.grid?.cols, 120)
        XCTAssertNil(hub.attachments["P"]?.sizedBy)
        let padState = try XCTUnwrap(sent.events(to: pad.id, RemoteProtocol.Event.paneState).last?.params(as: MirrorState.self))
        XCTAssertNil(padState.sizedBy)
    }

    func testADeviceThatSizedThePaneAndDisconnectsGivesTheSizeBack() throws {
        _ = try attach(phone, AttachParams(pane: "P", cols: 48, rows: 22))
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
        let count = sent.count(to: phone.id)
        hub.paneChanged("P")
        XCTAssertEqual(sent.count(to: phone.id), count)
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
        let resize = try RemoteRequest(id: 3, method: RemoteProtocol.Method.resize, params: GridParams(pane: "P", cols: 40, rows: 20))
        XCTAssertEqual(session.receive(try RemoteMessage.request(resize).encoded()), [.mirror(.resize(GridParams(pane: "P", cols: 40, rows: 20)), id: 3)])
        let bad = RemoteRequest(id: 4, method: RemoteProtocol.Method.input, params: .object(["text": .string("x")]))
        guard case .send(.response(let response)) = session.receive(try RemoteMessage.request(bad).encoded()).first,
              case .error(let error) = response.outcome else { return XCTFail("input without a pane was taken") }
        XCTAssertEqual(error.code, RemoteError.invalidParams)
    }
}

/// Over the network: a client attaches, gets the snapshot, then the output; types; sizes the pane.
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
        guard case .data(let frame) = try await task.receive() else { return XCTFail("output is a binary frame") }
        XCTAssertEqual(MirrorOutput(frame: frame), MirrorOutput(pane: "P", stream: "S1", seq: 8, data: Data("after\r\n".utf8)))

        guard case .response(let typed) = try await exchange(task, .request(try RemoteRequest(id: 3, method: RemoteProtocol.Method.input,
                                                                                                params: InputParams(pane: "P", text: "ls\r")))) else { return XCTFail() }
        XCTAssertEqual(typed.id, 3)
        // Typed as a notification: no answer, the key still goes in.
        try await task.send(.string(String(decoding: try RemoteMessage.notification(RemoteNotification(method: RemoteProtocol.Method.input,
                                                                                                         params: InputParams(pane: "P", text: "x"))).encoded(), as: UTF8.self)))
        let deadline = Date().addingTimeInterval(5)
        while await MainActor.run(body: { pane.inputs.count }) < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let inputs = await MainActor.run { pane.inputs }
        XCTAssertEqual(inputs, [InputParams(pane: "P", text: "ls\r"), InputParams(pane: "P", text: "x")])

        guard case .response(let sized) = try await exchange(task, .request(try RemoteRequest(id: 4, method: RemoteProtocol.Method.resize,
                                                                                                params: GridParams(pane: "P", cols: 50, rows: 20)))) else { return XCTFail() }
        XCTAssertEqual(try sized.result(as: MirrorState.self).cols, 50)
        let attachments = await MainActor.run { hub.attachments["P"]?.sizedBy }
        XCTAssertEqual(attachments, "phone")

        // Hanging up gives the size back.
        task.cancel(with: .goingAway, reason: nil)
        let hangUp = Date().addingTimeInterval(5)
        while await MainActor.run(body: { pane.grid?.cols }) != 120, Date() < hangUp { try await Task.sleep(for: .milliseconds(50)) }
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
