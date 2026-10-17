import AppKit
import CommandBlocks
import Foundation
import GhosttyBridge
import PaneActivity
import RemoteControl
import WorkspaceModel

/// What `promptty` asks, answered on the main thread (see `ControlServer`).
extension WorkspaceCoordinator {
    /// Most requests answer at once; `wait` answers when its command ends.
    func handleControl(_ request: ControlRequest, reply: @escaping (ControlResponse) -> Void) {
        if request.command == "wait", preferences.settings.remoteControl {
            wait(request, reply: reply)
        } else {
            reply(handleControl(request))
        }
    }

    func handleControl(_ request: ControlRequest) -> ControlResponse {
        guard preferences.settings.remoteControl else {
            return ControlResponse(status: .unreachable, text: "remote control is off (PrompTTY › Settings › Tabs › Command line)")
        }
        switch request.command {
        case "ls": return list(json: request.wantsJSON)
        case "new-tab": return newTab(request)
        case "split": return split(request)
        case "capture" where request.options["block"] != nil: return captureBlock(request)
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
        /// The newest commands run in it, newest last.
        let blocks: [BlockInfo]
    }

    private struct BlockInfo: Encodable {
        let id: String
        let command: String
        let running: Bool
        let exit: Int?
        let started: String
        let finished: String?

        init(_ record: CommandRecord) {
            id = record.id
            command = record.command
            running = record.running
            exit = record.exitCode
            started = BlockInfo.date.string(from: record.started)
            finished = record.finished.map(BlockInfo.date.string(from:))
        }

        nonisolated(unsafe) static let date = ISO8601DateFormatter()
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
                        remote: status.remoteHost,
                        blocks: (controller?.shell(for: pane.id)?.commands.records.suffix(10) ?? []).map(BlockInfo.init)
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
        let block = command.isEmpty ? nil : CommandLog.newID()
        let pane = newTab(in: state, running: command.isEmpty ? nil : command, workingDirectory: folder(for: request), commandID: block)
        if let block { pendingBlocks[block] = (pane, command) }
        if let label = request.options["label"] { setLabel(label, of: pane) }
        return created(pane, block: block, json: request.wantsJSON)
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
        let block = command.isEmpty ? nil : CommandLog.newID()
        guard let pane = split(source, direction: direction, workingDirectory: request.options["cwd"] != nil ? folder(for: request) : nil,
                               command: command.isEmpty ? nil : command, commandID: block) else { return .failed("could not split") }
        if let block { pendingBlocks[block] = (pane, command) }
        if let label = request.options["label"] { setLabel(label, of: pane) }
        return created(pane, block: block, json: request.wantsJSON)
    }

    /// The new pane's id, and its command's when it runs one. Without --json, the pane's id alone,
    /// as before.
    private func created(_ pane: PaneID, block: String?, json: Bool) -> ControlResponse {
        let id = pane.rawValue.uuidString
        var object = ["pane": id]
        if let block { object["block"] = block }
        return .ok(id, json: json ? Self.json(object) : nil)
    }

    private static func json(_ value: some Encodable) -> String? {
        (try? JSONEncoder.control.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func send(_ request: ControlRequest, to pane: PaneID) -> ControlResponse {
        guard let controller = controller(containing: pane), let surface = controller.surfaces[pane] else {
            return .failed("that pane has no terminal yet (open its tab once)")
        }
        let text = request.arguments.joined(separator: " ")
        let enter = request.flags.contains("enter")
        var block: String?
        let shell = controller.shell(for: pane)
        if enter, let shell, let id = shell.runFromControl(text) {
            // Run as if from the bar: now at a prompt, or at the one on its way.
            block = id
            pendingBlocks[id] = (pane, text)
        } else if !enter, let shell, shell.bar == .active {
            // At a prompt: into the bar.
            shell.editor.textView.setCommand(text)
        } else {
            if !text.isEmpty { surface.sendText(text) }
            if enter { surface.sendReturn() }
        }
        guard request.wantsJSON else { return .ok(block ?? "") }
        var object = ["pane": pane.rawValue.uuidString]
        if let block { object["block"] = block }
        return .ok(block ?? "", json: Self.json(object))
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

// MARK: Commands by id

extension WorkspaceCoordinator {
    /// A command's record and the pane it ran in: by its whole id, or the end of it (4 characters
    /// or more), with or without `block:`.
    private func findBlock(_ query: String) -> Result<(record: CommandRecord, pane: PaneID, controller: TerminalWindowController), ControlResponse> {
        var found: [(record: CommandRecord, pane: PaneID, controller: TerminalWindowController)] = []
        var candidates: [PaneTarget.Candidate] = []
        for controller in allControllers {
            for shell in controller.allShells() {
                for record in shell.commands.records {
                    found.append((record, shell.pane, controller))
                    candidates.append(.init(id: record.id, label: nil))
                }
            }
        }
        // Handed out, not started yet; forgotten once started or once their pane is gone.
        for (id, pending) in pendingBlocks {
            if found.contains(where: { $0.record.id == id }) {
                pendingBlocks[id] = nil
            } else if let controller = controller(containing: pending.pane) {
                found.append((CommandRecord.pending(id: id, command: pending.command), pending.pane, controller))
                candidates.append(.init(id: id, label: nil))
            } else {
                pendingBlocks[id] = nil
            }
        }
        let wanted = query.lowercased()
        switch PaneTarget.resolve(wanted, among: candidates) {
        case .found(let id): return .success(found.last { $0.record.id == id }!)
        case .missing: return .failure(ControlResponse(status: .target, text: "no command \(query) (promptty ls --json lists them)"))
        case .ambiguous(let matches):
            return .failure(ControlResponse(status: .target, text: "\(query) names more than one command:\n" + matches.joined(separator: "\n")))
        }
    }

    private struct BlockCapture: Encodable {
        let block: String
        let pane: String
        let command: String
        let running: Bool
        let exit: Int?
        let text: String?
    }

    /// `capture -b`: one command's output (or its command, or both as Markdown), read from the
    /// terminal's block for it.
    fileprivate func captureBlock(_ request: ControlRequest) -> ControlResponse {
        let match: (record: CommandRecord, pane: PaneID, controller: TerminalWindowController)
        switch findBlock(request.options["block"]!) {
        case .success(let found): match = found
        case .failure(let response): return response
        }
        let part: BlockPart = request.flags.contains("command") ? .command : .output
        var text: String?
        if let surface = match.controller.surfaces[match.pane], let shell = match.controller.shell(for: match.pane),
           let snapshot = surface.blockSnapshot(.all) {
            let commands = snapshot.blocks.map { surface.blockText(row: $0.row, part: .command) }
            if let index = shell.commands.blockIndex(of: match.record, commands: commands) {
                let row = snapshot.blocks[index].row
                if request.flags.contains("markdown") {
                    text = BlockMarkdown.format(command: surface.blockText(row: row, part: .command) ?? match.record.command,
                                                output: surface.blockText(row: row, part: .output) ?? "")
                } else {
                    text = Self.trimmed(surface.blockText(row: row, part: part) ?? "")
                }
            }
        }
        let capture = BlockCapture(block: match.record.id, pane: match.pane.rawValue.uuidString, command: match.record.command,
                                   running: match.record.running, exit: match.record.exitCode, text: text)
        guard let text else {
            let why = match.record.pending ? "\(match.record.id) has not started yet"
                : "the output of \(match.record.id) is no longer in the scrollback"
            return request.wantsJSON ? .ok("", json: Self.json(capture)) : .failed(why)
        }
        return .ok(text, json: request.wantsJSON ? Self.json(capture) : nil)
    }

    /// Without trailing blanks on each line or blank lines at the end (a block read before the
    /// next prompt is drawn ends in a row of spaces).
    static func trimmed(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { line in
            String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// `wait -b`: answers when the command ends, with its exit status (at once when it has
    /// ended); `--timeout` gives up with status 5.
    fileprivate func wait(_ request: ControlRequest, reply: @escaping (ControlResponse) -> Void) {
        let record: CommandRecord
        switch findBlock(request.options["block"]!) {
        case .success(let found): record = found.record
        case .failure(let response): return reply(response)
        }
        guard record.running else { return reply(Self.ended(record, json: request.wantsJSON)) }
        let id = record.id
        let json = request.wantsJSON
        // Answered once: by the command's end or by the timeout, whichever comes first.
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        let answer: (ControlResponse) -> Void = { response in
            guard !once.done else { return }
            once.done = true
            reply(response)
        }
        blockWaiters[id, default: []].append { finished in answer(Self.ended(finished, json: json)) }
        if let seconds = request.options["timeout"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                answer(ControlResponse(status: .timedOut, text: "\(id) is still running"))
            }
        }
    }

    /// A command ended: its waiters get their answer.
    func commandFinished(_ record: CommandRecord) {
        pendingBlocks[record.id] = nil
        guard let waiters = blockWaiters.removeValue(forKey: record.id) else { return }
        for waiter in waiters { waiter(record) }
    }

    private static func ended(_ record: CommandRecord, json: Bool) -> ControlResponse {
        let code = Int32(clamping: record.exitCode ?? 0)
        let object = BlockInfo(record)
        return ControlResponse(code: min(max(code, 0), 255), text: "", json: json ? Self.json(object) : nil)
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
