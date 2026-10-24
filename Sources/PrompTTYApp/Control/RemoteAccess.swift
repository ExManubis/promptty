import Foundation
import Observation
import RemoteServer

/// The remote API in the app (`RemoteServer`): on while Settings › Tabs › Remote access is, on the
/// Mac's Tailscale address. Without Tailscale running it waits, trying again every 30 seconds.
/// Settings shows its address and the devices connected.
@MainActor
@Observable
final class RemoteAccess {
    static let shared = RemoteAccess()

    enum State: Equatable {
        case off
        case starting
        /// "mikkels-studio.example.ts.net:7445", to connect to.
        case listening(address: String)
        case unavailable(String)
    }

    private(set) var state = State.off
    private(set) var clients: [RemoteServer.Client] = []

    private var server: RemoteServer?
    private var handler: RemoteServer.Handler?
    private var enabled = false
    private var attempts: Task<Void, Never>?

    /// Turns the server on or off; `handler` answers the control commands, as for `promptty`.
    func configure(enabled: Bool, handler: @escaping RemoteServer.Handler) {
        self.handler = handler
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled { start() } else { stop() }
    }

    func disconnect(_ id: UUID) { server?.disconnect(id) }

    private func start() {
        state = .starting
        attempts?.cancel()
        attempts = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.enabled, self.server == nil else { return }
                await self.attempt()
                if self.server != nil { return }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func attempt() async {
        guard let node = await TailscaleCLI.node(), let address = node.ipv4 else {
            state = .unavailable(TailscaleCLI.path == nil ? "Tailscale is not installed" : "Tailscale is not running or not logged in")
            return
        }
        guard enabled, let handler else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let server = RemoteServer(host: address, owner: node.ownerID, server: "PrompTTY \(version)", mac: TabStripView.computerName,
                                  identify: { await TailscaleCLI.whois($0) }, handler: handler,
                                  onClients: { clients in MainActor.assumeIsolated { RemoteAccess.shared.clients = clients } },
                                  onFailure: { reason in MainActor.assumeIsolated { RemoteAccess.shared.failed(reason) } })
        do {
            try server.start()
            self.server = server
            state = .listening(address: "\(node.dnsName.isEmpty ? address : node.dnsName):\(server.port)")
        } catch {
            state = .unavailable("could not listen on \(address): \(error)")
        }
    }

    /// The listener stopped (the address went away, or was taken): try again later.
    private func failed(_ reason: String) {
        server?.stop()
        server = nil
        clients = []
        guard enabled else { return }
        state = .unavailable(reason)
        start()
    }

    private func stop() {
        attempts?.cancel()
        attempts = nil
        server?.stop()
        server = nil
        clients = []
        state = .off
    }
}
