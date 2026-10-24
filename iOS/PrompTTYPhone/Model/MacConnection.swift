import Foundation
import GhosttyMirror
import os
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
    private(set) var client: RemoteClient?
    /// The pane shown live, if any (`LiveMirror`).
    private(set) var mirror: LiveMirror?
    /// The Mac's terminal config, for drawing its panes with its font and colors.
    private var terminalConfig: String?
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
        mirror?.detach()
        mirror = nil
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
                if let appearance = try? await client.call(RemoteProtocol.Method.appearance, as: RemoteAppearance.self) {
                    terminalConfig = appearance.config
                }
                // Back after a reconnect: the pane goes on from where it got to.
                if let mirror {
                    if mirror.view == nil { mirror.start(config: terminalConfig ?? "") } else { mirror.attach() }
                }
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
        case RemoteProtocol.Event.output:
            if let output = try? event.params(as: MirrorOutput.self), output.pane == mirror?.pane.uuidString { mirror?.received(output) }
        case RemoteProtocol.Event.paneState:
            if let state = try? event.params(as: MirrorState.self), state.pane == mirror?.pane.uuidString { mirror?.apply(state) }
        case RemoteProtocol.Event.detached:
            if let detached = try? event.params(as: Detached.self), detached.pane == mirror?.pane.uuidString { mirror?.detached(detached.reason) }
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

    /// Shows the pane live (nil: none), letting go of the one shown before.
    func showLive(_ pane: UUID?) {
        guard mirror?.pane != pane else { return }
        mirror?.detach()
        mirror = pane.map { LiveMirror(pane: $0, connection: self) }
        // A tab the phone opened: at the phone's size, then its command.
        if let mirror, let opening, opening.pane == mirror.pane {
            mirror.onFirstAttach = { [weak self, weak mirror] in
                mirror?.takeControl()
                if let command = opening.command { self?.run(command, in: opening.pane) }
            }
            self.opening = nil
        }
        if let mirror, client != nil, let terminalConfig { mirror.start(config: terminalConfig) }
    }

    /// A tab the phone just opened, and the command it opens with.
    private var opening: (pane: UUID, command: String?)?

    /// Where a new tab can open.
    func places() async -> RemotePlaces? {
        guard let client else { return nil }
        return try? await client.call(RemoteProtocol.Method.places, as: RemotePlaces.self)
    }

    /// Opens a tab on the Mac in `folder` (labelled iPhone), shown live here at the phone's size;
    /// `command` runs in it once it is.
    func openTab(folder: String?, command: String?) {
        guard let client else { return }
        var options = ["label": "iPhone"]
        if let folder { options["cwd"] = folder }
        Task {
            do {
                let response = try await client.call("new-tab", ControlParams(options: options), as: ControlResponse.self)
                guard response.status == 0, let pane = UUID(uuidString: response.text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return Self.log.error("new-tab: \(response.text, privacy: .public)")
                }
                opening = (pane, command)
                model?.open(pane: pane)
            } catch {
                Self.log.error("new-tab failed: \(MacConnection.describe(error), privacy: .public)")
            }
        }
    }

    /// Typed on the phone in the live pane: to the pane as keys, with the key row's latched
    /// Control and Option on the next one.
    func typed(_ input: MirrorInput, in mirror: LiveMirror?) {
        guard let client, let mirror else { return }
        let latched = model?.takeLatches() ?? []
        var params = InputParams(pane: mirror.pane.uuidString)
        switch input {
        case .text(let text) where !latched.isEmpty && text.count == 1:
            params.key = RemoteKey(text.lowercased(), mods: latched)
        case .text(let text):
            params.text = text
        case .paste(let text):
            params.paste = text
        case .key(let key, let modifiers):
            params.key = RemoteKey(Self.keyName(key), mods: Array(Set(Self.mods(modifiers) + latched)))
        }
        Task {
            do {
                _ = try await client.call(RemoteProtocol.Method.input, params, as: JSONValue.self)
            } catch {
                Self.log.error("input refused: \(MacConnection.describe(error), privacy: .public)")
            }
        }
    }

    static func keyName(_ key: MirrorKey) -> String {
        switch key {
        case .return: "enter"
        case .tab: "tab"
        case .escape: "escape"
        case .backspace: "backspace"
        case .forwardDelete: "delete"
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .home: "home"
        case .end: "end"
        case .pageUp: "pageUp"
        case .pageDown: "pageDown"
        case .character(let c): String(c)
        }
    }

    static func mods(_ modifiers: MirrorModifiers) -> [RemoteKey.Mod] {
        var mods: [RemoteKey.Mod] = []
        if modifiers.contains(.shift) { mods.append(.shift) }
        if modifiers.contains(.control) { mods.append(.ctrl) }
        if modifiers.contains(.option) { mods.append(.alt) }
        if modifiers.contains(.command) { mods.append(.super) }
        return mods
    }

    private static let log = Logger(subsystem: "dev.promptty.PrompTTY2.phone", category: "mirror")

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
