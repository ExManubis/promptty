import Foundation
import RemoteControl
import RemoteProtocol
import XCTest
@testable import RemoteServer

final class TailnetIdentityTests: XCTestCase {
    private let owner: Int64 = 2_773_550_612_190_809

    func testOnlyTheOwnersOwnDevicesGetIn() {
        let phone = TailnetIdentity.Caller(userID: owner, login: "me@github", device: "iphone")
        XCTAssertEqual(TailnetIdentity.decide(phone, owner: owner), .allowed(login: "me@github"))
        let someoneElse = TailnetIdentity.Caller(userID: 42, login: "them@github", device: "their-laptop")
        XCTAssertEqual(TailnetIdentity.decide(someoneElse, owner: owner), .refused("them@github is not this Mac's owner"))
        let server = TailnetIdentity.Caller(userID: owner, login: "me@github", tags: ["tag:server"], device: "ci")
        XCTAssertEqual(TailnetIdentity.decide(server, owner: owner), .refused("ci is a tagged device, not a person's"))
        XCTAssertEqual(TailnetIdentity.decide(nil, owner: owner), .refused("Tailscale does not know this caller"))
    }

    func testReadsTailscaleStatus() {
        let status = #"{"BackendState":"Running","Self":{"UserID":2773550612190809,"DNSName":"studio.example.ts.net.","TailscaleIPs":["100.108.20.24","fd7a:115c:a1e0::1"]}}"#
        let node = TailnetIdentity.node(fromStatus: Data(status.utf8))
        XCTAssertEqual(node, TailnetIdentity.Node(addresses: ["100.108.20.24", "fd7a:115c:a1e0::1"], dnsName: "studio.example.ts.net", ownerID: owner))
        XCTAssertEqual(node?.ipv4, "100.108.20.24")
        XCTAssertNil(TailnetIdentity.node(fromStatus: Data(#"{"BackendState":"Stopped"}"#.utf8)))
    }

    func testReadsTailscaleWhois() {
        let whois = #"{"Node":{"ComputedName":"iphone","Tags":["tag:x"]},"UserProfile":{"ID":2773550612190809,"LoginName":"me@github"}}"#
        XCTAssertEqual(TailnetIdentity.caller(fromWhois: Data(whois.utf8)),
                       TailnetIdentity.Caller(userID: owner, login: "me@github", tags: ["tag:x"], device: "iphone"))
        XCTAssertNil(TailnetIdentity.caller(fromWhois: Data("{}".utf8)))
    }
}

final class RemoteSessionTests: XCTestCase {
    private func session() -> RemoteSession { RemoteSession(server: "PrompTTY 2.1", mac: "Studio", user: "me@github") }

    private func data(_ message: RemoteMessage) throws -> Data { try message.encoded() }

    func testHelloComesFirst() throws {
        var session = session()
        let early = session.receive(try data(.request(RemoteRequest(id: 1, method: "ls"))))
        XCTAssertEqual(early, [.send(.response(.error(RemoteError(code: RemoteError.notIntroduced, message: "say hello first"), id: 1)))])
        let hello = session.receive(try data(.request(try RemoteRequest(id: 2, method: "hello", params: Hello(client: "phone")))))
        XCTAssertEqual(hello, [.send(.response(try .result(Welcome(server: "PrompTTY 2.1", mac: "Studio", user: "me@github"), id: 2)))])
        XCTAssertEqual(session.state, .introduced(client: "phone"))
    }

    func testAnotherVersionIsAnsweredAndHungUpOn() throws {
        var session = session()
        let actions = session.receive(try data(.request(try RemoteRequest(id: 1, method: "hello", params: Hello(protocolVersion: 99, client: "future")))))
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions.last, .close)
        guard case .send(.response(let response)) = actions.first, case .error(let error) = response.outcome else { return XCTFail("\(actions)") }
        XCTAssertEqual(error.code, RemoteError.unsupportedVersion)
    }

    func testControlCommandsGoToTheControlHandler() throws {
        var session = session()
        _ = session.receive(try data(.request(try RemoteRequest(id: 1, method: "hello", params: Hello(client: "phone")))))
        let send = session.receive(try data(.request(try RemoteRequest(id: 2, method: "send", params: ControlParams(target: "tests", arguments: ["make"], flags: ["enter"])))))
        XCTAssertEqual(send, [.control(ControlRequest(command: "send", target: "tests", arguments: ["make"], flags: ["enter"]), id: 2)])
        XCTAssertEqual(RemoteSession.reply(ControlResponse.ok("sent"), to: 2), .send(.response(try .result(ControlResponse.ok("sent"), id: 2))))
    }

    func testUnknownMethodsBadParamsAndGarbage() throws {
        var session = session()
        _ = session.receive(try data(.request(try RemoteRequest(id: 1, method: "hello", params: Hello(client: "phone")))))
        XCTAssertEqual(session.receive(try data(.request(RemoteRequest(id: 9, method: "subscribe")))), [.subscribe(id: 9)])
        XCTAssertEqual(session.receive(try data(.request(try RemoteRequest(id: 8, method: "blocks", params: BlocksParams(pane: "P", limit: 3))))),
                       [.blocks(BlocksParams(pane: "P", limit: 3), id: 8)])
        XCTAssertEqual(session.receive(try data(.request(RemoteRequest(id: 2, method: "rm-rf")))),
                       [.send(.response(.error(RemoteError(code: RemoteError.methodNotFound, message: "no method rm-rf"), id: 2)))])
        let badParams = session.receive(try data(.request(RemoteRequest(id: 3, method: "send", params: .object(["arguments": .int(1)])))))
        guard case .send(.response(let response)) = badParams.first, case .error(let error) = response.outcome else { return XCTFail() }
        XCTAssertEqual(error.code, RemoteError.invalidParams)
        XCTAssertEqual(session.receive(Data("not json".utf8)),
                       [.send(.response(.error(RemoteError(code: RemoteError.parseError, message: "not a JSON-RPC 2.0 message"), id: nil)))])
        XCTAssertEqual(session.receive(try data(.notification(RemoteNotification(method: "tick")))), [])
    }
}

/// The server on the loopback address, a WebSocket client talking to it.
final class RemoteServerTests: XCTestCase {
    private let owner: Int64 = 7

    private func makeServer(caller: TailnetIdentity.Caller?) throws -> RemoteServer {
        let port = UInt16.random(in: 40_000...60_000)
        let server = RemoteServer(host: "127.0.0.1", port: port, owner: owner, server: "PrompTTY test", mac: "Test Mac",
                                  identify: { _ in caller },
                                  handler: { request, reply in reply(.ok("ran \(request.command) \(request.arguments.joined(separator: " "))")) },
                                  onClients: { _ in })
        try server.start()
        return server
    }

    private func connect(_ server: RemoteServer) -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(server.port)")!)
        task.resume()
        return task
    }

    private func exchange(_ task: URLSessionWebSocketTask, _ message: RemoteMessage) async throws -> RemoteMessage {
        try await task.send(.string(String(decoding: message.encoded(), as: UTF8.self)))
        return try await receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) async throws -> RemoteMessage {
        switch try await task.receive() {
        case .string(let text): return try RemoteMessage.decode(Data(text.utf8))
        case .data(let data): return try RemoteMessage.decode(data)
        @unknown default: throw URLError(.cannotParseResponse)
        }
    }

    func testTheOwnerSaysHelloAndRunsACommand() async throws {
        let server = try makeServer(caller: TailnetIdentity.Caller(userID: owner, login: "me@github"))
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let task = connect(server)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let welcome = try await exchange(task, .request(try RemoteRequest(id: 1, method: "hello", params: Hello(client: "test"))))
        guard case .response(let response) = welcome else { return XCTFail("\(welcome)") }
        XCTAssertEqual(try response.result(as: Welcome.self), Welcome(server: "PrompTTY test", mac: "Test Mac", user: "me@github"))

        let sent = try await exchange(task, .request(try RemoteRequest(id: 2, method: "send", params: ControlParams(arguments: ["make", "test"]))))
        guard case .response(let answer) = sent else { return XCTFail("\(sent)") }
        XCTAssertEqual(answer.id, 2)
        XCTAssertEqual(try answer.result(as: ControlResponse.self), .ok("ran send make test"))
    }

    func testSomeoneElseIsToldNoAndHungUpOn() async throws {
        let server = try makeServer(caller: TailnetIdentity.Caller(userID: 99, login: "them@github"))
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let task = connect(server)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let refusal = try await receive(task)
        guard case .response(let response) = refusal, case .error(let error) = response.outcome else { return XCTFail("\(refusal)") }
        XCTAssertEqual(error.code, RemoteError.notAllowed)
        XCTAssertEqual(error.message, "them@github is not this Mac's owner")
    }
}

/// Subscribing: the workspace now, then its changes, and the commands that end.
final class RemoteSubscriptionTests: XCTestCase {
    private let owner: Int64 = 7

    private static func pane(_ state: RemotePaneState) -> RemoteWorkspace {
        RemoteWorkspace(windows: [RemoteWindow(id: "W", key: true, selectedTab: "T", tabs: [
            RemoteTab(id: "T", title: "claude", project: nil, pinned: false, focusedPane: "P", panes: [
                RemotePane(id: "P", title: "claude", folder: "/tmp", program: "claude", state: state),
            ]),
        ])], projects: [])
    }

    func testASubscriberGetsTheWorkspaceThenOnlyItsChanges() async throws {
        let port = UInt16.random(in: 40_000...60_000)
        let workspace = RemoteServer.Workspace(
            snapshot: { Self.pane(.working) },
            blocks: { params in .success(BlocksResult(pane: params.pane, commands: [])) })
        let server = RemoteServer(host: "127.0.0.1", port: port, owner: owner, server: "test", mac: "Mac",
                                  identify: { _ in TailnetIdentity.Caller(userID: 7, login: "me") },
                                  handler: { _, reply in reply(.ok()) }, workspace: workspace, onClients: { _ in })
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        _ = try await exchange(task, .request(try RemoteRequest(id: 1, method: "hello", params: Hello(client: "test"))))
        let subscribed = try await exchange(task, .request(RemoteRequest(id: 2, method: RemoteProtocol.Method.subscribe)))
        guard case .response(let response) = subscribed else { return XCTFail("\(subscribed)") }
        XCTAssertEqual(try response.result(as: RemoteWorkspace.self), Self.pane(.working))

        // The same workspace again is not sent; an agent starting to wait is, at once.
        server.publish(Self.pane(.working))
        let started = Date()
        server.publish(Self.pane(.permission))
        let event = try await receive(task)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        guard case .notification(let changed) = event else { return XCTFail("\(event)") }
        XCTAssertEqual(changed.method, RemoteProtocol.Event.workspace)
        XCTAssertEqual(try changed.params(as: RemoteWorkspace.self), Self.pane(.permission))

        let finished = CommandFinished(pane: "P", tab: "T", command: RemoteCommand(id: "cmd:1", command: "make", running: false, exitCode: 2, started: 1, finished: 2))
        server.publish(finished)
        guard case .notification(let ended) = try await receive(task) else { return XCTFail() }
        XCTAssertEqual(ended.method, RemoteProtocol.Event.commandFinished)
        XCTAssertEqual(try ended.params(as: CommandFinished.self), finished)

        let blocks = try await exchange(task, .request(try RemoteRequest(id: 3, method: RemoteProtocol.Method.blocks, params: BlocksParams(pane: "P"))))
        guard case .response(let listed) = blocks else { return XCTFail() }
        XCTAssertEqual(try listed.result(as: BlocksResult.self), BlocksResult(pane: "P", commands: []))
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
