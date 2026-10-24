import Foundation
import os
import RemoteProtocol
import RemoteServer

/// The phones the Mac pushes its notices to (`push.register` over the remote API), and sending
/// to them through the push relay set in Settings › Tabs › Remote access. A device APNs no longer
/// knows is forgotten.
@MainActor
@Observable
final class RemotePush {
    static let shared = RemotePush()

    private(set) var devices: PushDevices
    /// The relay's address; nil, nothing is sent.
    private(set) var relay: URL?
    private let file: URL
    private let log = Logger(subsystem: "dev.promptty.PrompTTY2", category: "push")

    init(file: URL = AppPaths.support.appendingPathComponent("push-devices.json")) {
        self.file = file
        devices = PushDevices.load(from: file)
    }

    func configure(relay text: String) {
        relay = PushSender.relayURL(text)
    }

    /// `push.register` (a registration) or `push.unregister` (none, its token).
    func handle(_ registration: PushRegistration?, token: String) -> Result<PushRegistered, RemoteError> {
        if let registration { devices.register(registration) } else { devices.unregister(token) }
        save()
        return .success(PushRegistered(token: token, relay: relay != nil))
    }

    func forget(_ token: String) {
        guard devices.unregister(token) else { return }
        save()
    }

    func send(_ notice: PushNotice) {
        guard let relay, !devices.devices(for: notice.kind).isEmpty else { return }
        let devices = devices
        Task {
            let outcomes = await PushSender.send(notice, devices: devices, relay: relay, transport: PushSender.urlSession)
            for (token, outcome) in outcomes {
                switch outcome {
                case .sent: break
                case .gone: forget(token)
                case .failed(let reason): log.error("push failed: \(reason, privacy: .public)")
                }
            }
        }
    }

    private func save() {
        do { try devices.save(to: file) } catch { log.error("can't keep the push devices: \(error.localizedDescription, privacy: .public)") }
    }
}
