import AppKit
import WorkspaceModel

/// The command palette (⇧⌘P) over this window.
extension TerminalWindowController {
    @objc func togglePalette(_ sender: Any?) {
        if chrome.palette != nil { return closePalette(running: nil) }
        // Built while the terminal still has the keys, so the menu commands validate against it.
        chrome.palette = PaletteModel(entries: paletteEntries())
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
        let commands = MenuCommands.entries(in: NSApp.mainMenu, window: window)
        let app = commands.filter { $0.subtitle == "PrompTTY" }
        return tabEntries() + projectEntries() + commands.filter { $0.subtitle != "PrompTTY" } + app
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
                var subtitle = [tab.listSubtitle, agent.map { _ in "agent" }]
                subtitle.append(current ? "this tab" : number > 0 ? "tab in another window" : "tab")
                let entry = PaletteEntry(
                    id: "tab:\(tab.id)",
                    icon: agent != nil ? "sparkle" : tab.pin != nil ? "pin" : "terminal",
                    title: tab.listTitle,
                    subtitle: subtitle.compactMap { $0 }.joined(separator: " · "),
                    keywords: "tab \(tab.workingDirectory) \(tab.customTitle ?? "")",
                    run: { [weak self] in self?.coordinator.reveal(pane) }
                )
                if current { selected = entry } else { entries.append(entry) }
            }
        }
        return entries + [selected].compactMap { $0 }
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
