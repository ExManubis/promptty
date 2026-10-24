import Foundation
import RemoteClient
import RemoteControl
import RemoteProtocol

/// The phone's connection to one Mac's PrompTTY (its remote API, over Tailscale): it says hello,
/// subscribes to the workspace and keeps the model in step with every event, reads the output of
/// the commands a pane shows, and runs what is typed in the input bar. Gone, it tries again.
@MainActor
final class MacConnection {
    enum State: Equatable {
        case connecting
        case connected(mac: String)
        case failed(String)

        /// What to say under the Mac's name; nil once connected.
        var message: String? {
            switch self {
            case .connecting: "Connecting…"
            case .connected: nil
            case .failed(let reason): reason
            }
        }
    }

    /// The remote API's port on every Mac.
    static let port = 7445

    let mac: PhoneMac
    private weak var model: PhoneModel?
    private var client: RemoteClient?
    private var retry: Task<Void, Never>?
    private var stopped = false
    /// The output of the commands read so far, by command id.
    private var outputs: [String: [TerminalLine]] = [:]
    private var reading: Set<String> = []
    private var latest: RemoteWorkspace?

    init(mac: PhoneMac, model: PhoneModel) {
        self.mac = mac
        self.model = model
    }

    /// "ws://mikkels-studio:7445": the host as typed, the remote API's port unless one is given.
    static func url(for host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withPort = trimmed.contains(":") ? trimmed : "\(trimmed):\(port)"
        return URL(string: "ws://\(withPort)")
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        retry?.cancel()
        client?.close()
        client = nil
    }

    private func connect() {
        guard !stopped, let url = Self.url(for: mac.host) else {
            return model?.connectionChanged(.failed("\(mac.host) is not a Mac's name"), for: mac.id) ?? ()
        }
        model?.connectionChanged(.connecting, for: mac.id)
        let client = RemoteClient(url: url, clientName: "PrompTTY for iPhone")
        self.client = client
        client.onEvent { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        client.onClose { [weak self] error in
            Task { @MainActor in self?.closed(error, client: client) }
        }
        Task {
            do {
                let welcome = try await client.connect()
                let workspace = try await client.call(RemoteProtocol.Method.subscribe, as: RemoteWorkspace.self)
                guard self.client === client else { return }
                model?.connectionChanged(.connected(mac: welcome.mac), for: mac.id)
                apply(workspace)
            } catch {
                closed(error, client: client)
            }
        }
    }

    private func closed(_ error: Error?, client: RemoteClient) {
        guard self.client === client, !stopped else { return }
        self.client = nil
        model?.connectionChanged(.failed(Self.describe(error)), for: mac.id)
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func handle(_ event: RemoteNotification) {
        switch event.method {
        case RemoteProtocol.Event.workspace:
            if let workspace = try? event.params(as: RemoteWorkspace.self) { apply(workspace) }
        case RemoteProtocol.Event.commandFinished:
            // Its output, once the workspace that lists it has come: read now, so the pane shows it.
            if let finished = try? event.params(as: CommandFinished.self) {
                outputs[finished.command.id] = nil
                readOutputs([finished.command.id])
            }
        default:
            break
        }
    }

    private func apply(_ workspace: RemoteWorkspace) {
        latest = workspace
        guard let model else { return }
        model.applyRemote(RemoteMapping.projects(workspace, outputs: outputs, previous: model.projects))
    }

    /// Reads the output of a pane's newest commands, those not read yet.
    func readOutputs(of pane: PhonePane) {
        readOutputs(Array(pane.commandIDs.suffix(5)))
    }

    private func readOutputs(_ ids: [String]) {
        guard let client else { return }
        for id in ids where outputs[id] == nil && !reading.contains(id) {
            reading.insert(id)
            Task {
                let response = try? await client.call("capture", ControlParams(options: ["cmd": id]), as: ControlResponse.self)
                reading.remove(id)
                guard let response, response.status == 0 else { return }
                outputs[id] = RemoteMapping.lines(response.text)
                if let latest { apply(latest) }
            }
        }
    }

    /// Types the command into the pane and presses Return, as `promptty send --enter` does.
    func run(_ command: String, in pane: UUID) {
        guard let client else { return }
        Task {
            _ = try? await client.call("send", ControlParams(target: pane.uuidString, arguments: [command], flags: ["enter"]),
                                       as: ControlResponse.self)
        }
    }

    /// Presses a key in the pane, which waits for permission (`answer`). A pane that no longer
    /// waits refuses it: the workspace event that says so is on its way.
    func answer(_ key: String, in pane: UUID) {
        guard let client else { return }
        Task {
            _ = try? await client.call(RemoteProtocol.Method.answer, AnswerParams(pane: pane.uuidString, key: key), as: AnswerResult.self)
        }
    }

    static func describe(_ error: Error?) -> String {
        switch error {
        case let remote as RemoteError where remote.code == RemoteError.notAllowed: "Not allowed: \(remote.message)"
        case let remote as RemoteError: remote.message
        case let url as URLError where url.code == .cannotFindHost || url.code == .cannotConnectToHost:
            "Can't reach it. Is Tailscale on, and Remote access on in PrompTTY's Settings?"
        case let url as URLError where url.code == .timedOut: "It doesn't answer."
        case .some(let error): error.localizedDescription
        case nil: "Disconnected"
        }
    }
}
