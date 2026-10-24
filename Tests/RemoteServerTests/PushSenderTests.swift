import Foundation
import RemoteProtocol
import XCTest
@testable import RemoteServer

final class PushSenderTests: XCTestCase {
    private func device(_ token: String, kinds: [PushKind], key: Data = PushSeal.newKey()) -> PushRegistration {
        PushRegistration(token: token, environment: "development", device: "iPhone", kinds: kinds.map(\.rawValue), keyID: "K-\(token.prefix(4))",
                         key: key.base64EncodedString())
    }

    func testADeviceRegisteredAgainReplacesItselfAndIsKeptPrivately() throws {
        var devices = PushDevices()
        devices.register(device("aa11", kinds: [.permission]))
        devices.register(device("aa11", kinds: [.done]))
        devices.register(device("bb22", kinds: [.permission, .command]))
        XCTAssertEqual(devices.devices.map(\.token), ["aa11", "bb22"])
        XCTAssertEqual(devices.devices(for: .permission).map(\.token), ["bb22"])
        XCTAssertTrue(devices.unregister("aa11"))
        XCTAssertFalse(devices.unregister("aa11"))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("push-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try devices.save(to: url)
        XCTAssertEqual(PushDevices.load(from: url), devices)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testSendsEachDeviceThatWantsItANoticeOnlyItsKeyOpens() async throws {
        let key = PushSeal.newKey()
        var devices = PushDevices()
        devices.register(device("aa11", kinds: [.permission], key: key))
        devices.register(device("bb22", kinds: [.done]))
        devices.register(device("cc33", kinds: [.permission]))
        let notice = PushNotice(kind: .permission, title: "Claude Code", body: "Needs your permission to use Bash", mac: "Studio", pane: "P1")
        let sent = Sent()
        let outcomes = await PushSender.send(notice, devices: devices, relay: URL(string: "https://relay.example/push")!) { request in
            await sent.add(request)
            let push = try JSONDecoder().decode(RelayPush.self, from: request.httpBody ?? Data())
            return push.token == "cc33" ? 410 : 200
        }
        XCTAssertEqual(outcomes, ["aa11": .sent, "cc33": .gone])
        let requests = await sent.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        let body = try XCTUnwrap(requests[0].httpBody)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("Bash"), "the relay sees ciphertext only")
        let push = try JSONDecoder().decode(RelayPush.self, from: body)
        XCTAssertEqual(push.keyID, "K-aa11")
        XCTAssertEqual(try PushSeal.open(push.sealed, key: key), notice)
    }

    func testARelayAddressIsHTTPWithAHost() {
        XCTAssertNotNil(PushSender.relayURL(" https://promptty-push.example.workers.dev/push "))
        XCTAssertNotNil(PushSender.relayURL("http://munin-1:8790/push"))
        XCTAssertNil(PushSender.relayURL(""))
        XCTAssertNil(PushSender.relayURL("munin-1:8790"))
        XCTAssertNil(PushSender.relayURL("file:///etc/passwd"))
    }
}

private actor Sent {
    var requests: [URLRequest] = []
    func add(_ request: URLRequest) { requests.append(request) }
}
