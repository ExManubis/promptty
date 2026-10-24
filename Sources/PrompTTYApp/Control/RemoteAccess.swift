import Foundation
import Observation
import RemoteProtocol
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
    private(set) var clients: [RemoteServer.Client] = [] {
        didSet { if clients.isEmpty != oldValue.isEmpty { publishWhileConnected() } }
    }

    private var server: RemoteServer?
    private var handler: RemoteServer.Handler?
    private var workspace: RemoteServer.Workspace?
    private var publishing: Task<Void, Never>?
    private var enabled = false
    private var attempts: Task<Void, Never>?

    /// Turns the server on or off; `handler` answers the control commands, as for `promptty`, and
    /// `workspace` is what subscribers see.
    func configure(enabled: Bool, handler: @escaping RemoteServer.Handler, workspace: RemoteServer.Workspace) {
        self.handler = handler
        self.workspace = workspace
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled { start() } else { stop() }
    }

    func disconnect(_ id: UUID) { server?.disconnect(id) }

    /// A command ended: subscribers are told.
    func publish(_ finished: CommandFinished) { server?.publish(finished) }

    /// While a device is connected, the workspace is looked at twice a second and sent to its
    /// subscribers when it changed (the server keeps what each was sent last). Cheap: a Mac has
    /// tens of panes, not thousands.
    private func publishWhileConnected() {
        publishing?.cancel()
        publishing = nil
        guard !clients.isEmpty else { return }
        publishing = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let server = self.server, let workspace = self.workspace else { return }
                server.publish(workspace.snapshot())
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

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
        var identify: RemoteServer.Identify = { await TailscaleCLI.whois($0) }
        #if DEBUG
        // PROMPTTY_REMOTE_HOST=127.0.0.1: the loopback address instead of Tailscale's, everyone on
        // it taken for the owner. For driven runs and the iPhone app in the Simulator, which
        // cannot reach the Mac's own Tailscale address. Never in a release build.
        let debugHost = ProcessInfo.processInfo.environment["PROMPTTY_REMOTE_HOST"]
        if debugHost != nil { identify = { _ in TailnetIdentity.Caller(userID: 0, login: "debug") } }
        let found: TailnetIdentity.Node?
        if let debugHost {
            found = TailnetIdentity.Node(addresses: [debugHost], dnsName: "", ownerID: 0)
        } else {
            found = await TailscaleCLI.node()
        }
        #else
        let found = await TailscaleCLI.node()
        #endif
        guard let node = found, let address = node.ipv4 else {
            state = .unavailable(TailscaleCLI.path == nil ? "Tailscale is not installed" : "Tailscale is not running or not logged in")
            return
        }
        guard enabled, let handler else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let server = RemoteServer(host: address, owner: node.ownerID, server: "PrompTTY \(version)", mac: TabStripView.computerName,
                                  identify: identify, handler: handler, workspace: workspace,
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
