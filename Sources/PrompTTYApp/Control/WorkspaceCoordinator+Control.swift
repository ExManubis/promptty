import AppKit
import Foundation
import GhosttyBridge
import PaneActivity
import RemoteControl
import WorkspaceModel

/// What `promptty` asks, answered on the main thread (see `ControlServer`).
extension WorkspaceCoordinator {
    func handleControl(_ request: ControlRequest) -> ControlResponse {
        guard preferences.settings.remoteControl else {
            return ControlResponse(status: .unreachable, text: "remote control is off (PrompTTY › Settings › Tabs › Command line)")
        }
        switch request.command {
        case "ls": return list(json: request.wantsJSON)
        case "new-tab": return newTab(request)
        case "split": return split(request)
        case "send", "capture", "focus", "label", "notify": break
        default: return ControlResponse(status: .usage, text: "unknown command \(request.command)")
        }
        // The rest act on a pane: the one named, else the caller's.
        let pane: PaneID
        switch resolvePane(request) {
        case .success(let found): pane = found
        case .failure(let response): return response
        }
        switch request.command {
        case "send": return send(request, to: pane)
        case "capture": return capture(pane, all: request.flags.contains("all"))
        case "focus":
            reveal(pane)
            return .ok()
        case "label":
            setLabel(request.arguments.joined(separator: " "), of: pane)
            return .ok()
        default: // notify
            let title = request.arguments.first ?? ""
            let body = request.arguments.dropFirst().joined(separator: " ")
            Notifications.post(title: title, body: body, pane: pane)
            #if DEBUG
            postedNotices.append("\(title) — \(body)")
            #endif
            return .ok()
        }
    }

    private func resolvePane(_ request: ControlRequest) -> Result<PaneID, ControlResponse> {
        guard let query = request.target ?? request.caller else {
            return .failure(ControlResponse(status: .target, text: "no pane: run this in a PrompTTY pane, or name one with -p"))
        }
        var candidates: [PaneTarget.Candidate] = []
        var ids: [String: PaneID] = [:]
        for window in workspace.windows {
            for tab in window.tabs {
                for pane in tab.orderedPanes {
                    let id = pane.id.rawValue.uuidString
                    candidates.append(.init(id: id, label: pane.label))
                    ids[id] = pane.id
                }
            }
        }
        switch PaneTarget.resolve(query, among: candidates) {
        case .found(let id): return .success(ids[id]!)
        case .missing: return .failure(ControlResponse(status: .target, text: "no pane \(query)"))
        case .ambiguous(let matches):
            return .failure(ControlResponse(status: .target, text: "\(query) names more than one pane:\n" + matches.joined(separator: "\n")))
        }
    }

    // MARK: Commands

    private struct PaneInfo: Encodable {
        let id: String
        let label: String?
        let title: String
        let folder: String
        let focused: Bool
        let program: String?
        let state: String
        let ports: [Int]
        let remote: String?
    }

    private struct TabInfo: Encodable {
        let id: String
        let title: String
        let selected: Bool
        let pinned: Bool
        let project: String?
        let panes: [PaneInfo]
    }

    private struct WindowInfo: Encodable {
        let id: String
        let key: Bool
        let tabs: [TabInfo]
    }

    private func list(json: Bool) -> ControlResponse {
        var windows: [WindowInfo] = []
        var lines: [String] = []
        for (w, window) in workspace.windows.enumerated() {
            let controller = controller(for: window.id)
            var tabs: [TabInfo] = []
            for (t, tab) in window.tabs.enumerated() {
                var panes: [PaneInfo] = []
                for pane in tab.orderedPanes {
                    let activity = self.activity.activity(for: pane.id)
                    let status = self.activity.status(for: pane.id)
                    let info = PaneInfo(
                        id: pane.id.rawValue.uuidString, label: pane.label, title: pane.title,
                        folder: pane.workingDirectory, focused: pane.id == tab.focusedPaneID,
                        program: activity.program?.id, state: "\(activity.display)", ports: status.ports,
                        remote: status.remoteHost
                    )
                    panes.append(info)
                    let id = String(info.id.suffix(8)).lowercased()
                    let what = [info.program, info.state == "idle" ? nil : info.state, info.ports.isEmpty ? nil : info.ports.map { ":\($0)" }.joined(separator: " ")]
                        .compactMap { $0 }.joined(separator: " ")
                    lines.append("\(w + 1).\(t + 1)  \(id)  \((info.label ?? "-").padding(toLength: 10, withPad: " ", startingAt: 0))  \(Tab.abbreviate(info.folder))\(what.isEmpty ? "" : "  " + what)\(info.focused && tab.hasSplits ? "  *" : "")")
                }
                let project = window.project(of: tab).flatMap { workspace.project(id: $0)?.name }
                tabs.append(TabInfo(id: tab.id.rawValue.uuidString, title: tab.listTitle, selected: tab.id == window.selectedTabID,
                                    pinned: tab.pin != nil, project: project, panes: panes))
            }
            windows.append(WindowInfo(id: window.id.rawValue.uuidString, key: controller?.window?.isKeyWindow == true, tabs: tabs))
        }
        let encoded = json ? (try? JSONEncoder.control.encode(["windows": windows])).map { String(decoding: $0, as: UTF8.self) } : nil
        return .ok(lines.joined(separator: "\n"), json: encoded)
    }

    /// The window to open in: the caller's, else the key one.
    private func window(for request: ControlRequest) -> WindowState? {
        if let caller = request.caller.flatMap(UUID.init(uuidString:)), let (state, _) = workspace.tab(containing: PaneID(rawValue: caller)) {
            return state
        }
        return allControllers.first { $0.window?.isKeyWindow == true }?.state ?? workspace.windows.first
    }

    private func folder(for request: ControlRequest) -> String? {
        if let cwd = request.options["cwd"] {
            let path = (cwd as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return path
        }
        return request.caller.flatMap(UUID.init(uuidString:)).flatMap { workspace.tab(containing: PaneID(rawValue: $0))?.1.pane(PaneID(rawValue: $0))?.workingDirectory }
    }

    private func newTab(_ request: ControlRequest) -> ControlResponse {
        guard let state = window(for: request) else { return .failed("no window to open a tab in") }
        if request.options["cwd"] != nil, folder(for: request) == nil { return .failed("no folder \(request.options["cwd"]!)") }
        let command = ShellWords.join(request.arguments)
        let pane = newTab(in: state, running: command.isEmpty ? nil : command, workingDirectory: folder(for: request))
        return created(pane, json: request.wantsJSON)
    }

    private func split(_ request: ControlRequest) -> ControlResponse {
        let direction: SplitDirection = request.arguments.first == "down" ? .down : .right
        let source: PaneID
        switch resolvePane(request) {
        case .success(let found): source = found
        case .failure(let response): return response
        }
        if request.options["cwd"] != nil, folder(for: request) == nil { return .failed("no folder \(request.options["cwd"]!)") }
        let command = ShellWords.join(Array(request.arguments.dropFirst()))
        guard let pane = split(source, direction: direction, workingDirectory: request.options["cwd"] != nil ? folder(for: request) : nil,
                               command: command.isEmpty ? nil : command) else { return .failed("could not split") }
        return created(pane, json: request.wantsJSON)
    }

    private func created(_ pane: PaneID, json: Bool) -> ControlResponse {
        let id = pane.rawValue.uuidString
        return .ok(id, json: json ? "{\"pane\": \"\(id)\"}" : nil)
    }

    private func send(_ request: ControlRequest, to pane: PaneID) -> ControlResponse {
        guard let controller = controller(containing: pane), let surface = controller.surfaces[pane] else {
            return .failed("that pane has no terminal yet (open its tab once)")
        }
        let text = request.arguments.joined(separator: " ")
        let enter = request.flags.contains("enter")
        if let shell = controller.shell(for: pane), shell.bar == .active {
            // At a prompt: into the bar, or run as if from it.
            if enter { shell.receiveBroadcast(text) } else { shell.editor.textView.setCommand(text) }
        } else {
            if !text.isEmpty { surface.sendText(text) }
            if enter { surface.sendReturn() }
        }
        return .ok()
    }

    private func capture(_ pane: PaneID, all: Bool) -> ControlResponse {
        guard let surface = controller(containing: pane)?.surfaces[pane] else {
            return .failed("that pane has no terminal yet (open its tab once)")
        }
        let text = (all ? surface.allText(styled: false) : surface.visibleText()) ?? ""
        // Without the blank rows below the last line.
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return .ok(lines.joined(separator: "\n"))
    }
}

/// Words for a shell: as they were given to `promptty`, each quoted when it needs it.
enum ShellWords {
    static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }

    static func quote(_ word: String) -> String {
        guard !word.isEmpty else { return "''" }
        let plain = word.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }
        return plain ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
