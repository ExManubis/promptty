import AppKit
import PaneActivity
import Preferences
import WorkspaceModel

/// The command palette (⌘K) over this window.
extension TerminalWindowController {
    @objc func togglePalette(_ sender: Any?) {
        if chrome.palette != nil { return closePalette(running: nil) }
        // Built while the terminal still has the keys, so the menu commands validate against it.
        chrome.palette = PaletteModel(entries: paletteEntries())
    }

    /// Go to Folder (⌘J): the folders worked in, best first, and the open tabs' folders. Return
    /// changes the focused pane's folder (at a prompt; else a new tab opens there), ⌘Return opens a
    /// new tab there.
    @objc func goToFolder(_ sender: Any?) {
        if chrome.palette != nil { return closePalette(running: nil) }
        chrome.palette = PaletteModel(entries: folderEntries(), kind: .folders)
    }

    private func folderEntries() -> [PaletteEntry] {
        let fm = FileManager.default
        let open = Set(coordinator.workspace.windows.flatMap { $0.tabs.flatMap { $0.orderedPanes.map(\.workingDirectory) } })
        var seen = Set<String>()
        var entries: [PaletteEntry] = []
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        func add(_ directory: String, subtitle: String?) {
            var isDirectory: ObjCBool = false
            guard seen.insert(directory).inserted, fm.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            entries.append(PaletteEntry(
                id: "folder:\(directory)", icon: open.contains(directory) ? "folder.fill" : "folder",
                title: Tab.abbreviate(directory), subtitle: subtitle, keywords: (directory as NSString).lastPathComponent,
                run: { [weak self] in self?.changeFolder(to: directory) },
                alternate: { [weak self] in
                    guard let self else { return }
                    self.coordinator.newTab(in: self.state, running: nil, workingDirectory: directory)
                }
            ))
        }
        for visited in FolderHistoryStore.shared.frecentFolders() {
            let commands = visited.commands == 1 ? "1 command" : "\(visited.commands) commands"
            add(visited.directory, subtitle: "\(commands) · \(formatter.localizedString(for: visited.last, relativeTo: Date()))")
        }
        for directory in open.sorted() { add(directory, subtitle: "open") }
        return entries
    }

    /// `cd` in the focused pane at its prompt; with a program running there, a new tab instead.
    private func changeFolder(to directory: String) {
        guard let pane = state.selectedTab?.focusedPaneID, let shell = shell(for: pane), shell.bar == .active else {
            coordinator.newTab(in: state, running: nil, workingDirectory: directory)
            return
        }
        shell.changeDirectory(to: directory)
    }

    func closePalette(running entry: PaletteEntry?) {
        guard chrome.palette != nil else { return }
        chrome.palette = nil
        focusSelectedPane()
        // Once the keys are back with the pane, so the command reaches it.
        if let entry {
            DispatchQueue.main.async { MainActor.assumeIsolated { entry.run() } }
        }
    }

    private func paletteEntries() -> [PaletteEntry] {
        // The app menu's commands (About, Hide, Quit) are seldom what is looked for: last.
        let shortcuts = coordinator.preferences.shortcuts
        let commands = MenuCommands.entries(in: NSApp.mainMenu, window: window) { title in
            ShortcutAction.allCases.first { $0.title == title && $0 != .quickTerminal }
                .map { shortcuts.shortcut(for: $0).displayString }
        }
        let app = commands.filter { $0.subtitle == "PrompTTY" }
        return tabEntries() + projectEntries() + commands.filter { $0.subtitle != "PrompTTY" } + sshEntries() + app
    }

    /// Every tab in every window, this window's first, the selected one last (it is where you are).
    private func tabEntries() -> [PaletteEntry] {
        let windows = coordinator.workspace.windows
        let ordered = windows.filter { $0.id == state.id } + windows.filter { $0.id != state.id }
        var entries: [PaletteEntry] = []
        var selected: PaletteEntry?
        for (number, window) in ordered.enumerated() {
            for tab in window.tabs {
                let pane = tab.focusedPaneID
                let agent = coordinator.agentList.summary(for: tab.id)
                let current = window.id == state.id && tab.id == state.selectedTabID
                let labels = tab.orderedPanes.compactMap(\.label)
                var subtitle = [labels.isEmpty ? nil : labels.joined(separator: ", "), tab.listSubtitle, agent.map { _ in "agent" }]
                subtitle.append(current ? "this tab" : number > 0 ? "tab in another window" : "tab")
                let entry = PaletteEntry(
                    id: "tab:\(tab.id)",
                    icon: agent != nil ? "sparkle" : tab.pin != nil ? "pin" : "terminal",
                    title: tab.listTitle,
                    subtitle: subtitle.compactMap { $0 }.joined(separator: " · "),
                    keywords: "tab \(tab.workingDirectory) \(tab.customTitle ?? "") \(labels.joined(separator: " "))",
                    run: { [weak self] in self?.coordinator.reveal(pane) }
                )
                if current { selected = entry } else { entries.append(entry) }
            }
        }
        return entries + [selected].compactMap { $0 }
    }

    /// A new tab connected to each host in `~/.ssh/config`.
    private func sshEntries() -> [PaletteEntry] {
        SSHHosts.read().map { host in
            PaletteEntry(
                id: "ssh:\(host)",
                icon: "globe",
                title: "SSH to \(host)",
                subtitle: "~/.ssh/config",
                keywords: "ssh remote connect",
                run: { [weak self] in
                    guard let self else { return }
                    self.coordinator.newTab(in: self.state, running: "ssh \(SSHHosts.quoted(host))")
                }
            )
        }
    }

    private func projectEntries() -> [PaletteEntry] {
        coordinator.workspace.projects.map { project in
            PaletteEntry(
                id: "project:\(project.id)",
                icon: "folder.badge.plus",
                title: "New Tab in \(project.name)",
                subtitle: "Project",
                keywords: "project",
                run: { [weak self] in self?.newTab(inProject: project.id) }
            )
        }
    }
}

/// The hosts in the user's ssh config, read when the palette opens.
enum SSHHosts {
    static func read() -> [String] {
        let dir = AppPaths.sshDirectory
        guard let text = try? String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8) else { return [] }
        return SSHConfig.hosts(in: text) { pattern in
            // Relative to ~/.ssh, as ssh reads them; `~` is the home folder.
            let expanded = (pattern as NSString).expandingTildeInPath
            let full = expanded.hasPrefix("/") ? expanded : dir.appendingPathComponent(expanded).path
            return glob(full).compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        }
    }

    /// Shell-safe: a host from a config file is not trusted to be a plain word.
    static func quoted(_ host: String) -> String {
        host.allSatisfy { $0.isLetter || $0.isNumber || "-._@".contains($0) } ? host : "'" + host.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func glob(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { String(cString: $0) } }
    }
}
