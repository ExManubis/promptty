import AppKit
import CommandEditing
import GhosttyBridge
import PaneActivity
import Preferences
import WorkspaceModel

/// Owns the mapping between the model, window controllers, and surfaces, and is libghostty's action sink.
@MainActor
final class WorkspaceCoordinator: GhosttyActionSink {
    let runtime: GhosttyRuntime
    let workspace: Workspace
    let preferences: PreferencesController
    private var controllers: [WindowID: TerminalWindowController] = [:]
    /// What runs in each pane and what happened there unseen.
    let activity = ActivityTracker()
    /// Schedules a session save.
    var onModelChanged: (() -> Void)?

    init(runtime: GhosttyRuntime, workspace: Workspace, preferences: PreferencesController) {
        self.runtime = runtime
        self.workspace = workspace
        self.preferences = preferences
        activity.panes = { [weak self] in self?.watchedPanes() ?? [] }
        activity.onNotice = { [weak self] pane, notice in self?.post(notice, for: pane) }
        activity.onSeen = { Notifications.remove(for: $0) }
    }

    /// Opens a controller for every window in the model; creates a default window if none.
    func start() {
        if workspace.windows.isEmpty {
            let w = workspace.addWindow()
            w.addTab(title: "", workingDirectory: NSHomeDirectory())
        }
        for state in workspace.windows {
            if state.isEmpty { state.addTab(title: "", workingDirectory: NSHomeDirectory()) }
            open(state)
        }
        controllers.values.first?.window?.makeKeyAndOrderFront(nil)
        activity.start()
    }

    // MARK: Activity

    /// Every pane with a terminal, and whether the user sees it: the app in front, its window key
    /// and on screen, its tab selected.
    private func watchedPanes() -> [ActivityTracker.Watched] {
        let active = NSApp.isActive
        var watched: [ActivityTracker.Watched] = []
        for controller in controllers.values {
            let window = controller.window
            // Main, not key: a sheet, a picker's popover or the Settings window can have the keys
            // while the user looks at this window.
            let windowSeen = active && window?.isMainWindow == true && window?.occlusionState.contains(.visible) == true
            for tab in controller.state.tabs {
                let tabSeen = windowSeen && controller.state.selectedTabID == tab.id
                for pane in tab.orderedPanes {
                    guard let surface = controller.existingSurface(for: pane.id) else { continue }
                    watched.append(ActivityTracker.Watched(
                        pane: pane.id,
                        foregroundPID: surface.foregroundPID,
                        shellPID: controller.shell(for: pane.id)?.state.shellPID,
                        seen: tabSeen,
                        screen: { [weak surface] in surface?.activeScreenText() },
                        quietUntil: [surface.lastResize.map { $0.addingTimeInterval(1.5) },
                                     surface.lastKeyPress.map { $0.addingTimeInterval(1) }].compactMap { $0 }.max()
                    ))
                }
            }
        }
        return watched
    }

    private func post(_ notice: Notice, for pane: PaneID) {
        guard let (state, tab) = workspace.tab(containing: pane) else { return }
        // A finished command is the bar's last one; an attention is about whatever runs now.
        // The pane's own title, or its folder as the tab shows it.
        var command = tab.pane(pane).map { pane -> String in
            let title = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty || title == pane.workingDirectory ? Tab.abbreviate(pane.workingDirectory) : title
        }
        if case .attention = notice.kind {} else if let fromBar = controllers[state.id]?.shell(for: pane)?.lastCommand {
            command = fromBar
        }
        Notifications.post(title: notice.title(command: command), body: notice.body, pane: pane)
        #if DEBUG
        postedNotices.append("\(notice.title(command: command)) — \(notice.body)")
        #endif
    }

    #if DEBUG
    /// Notices posted, for the debug driver.
    var postedNotices: [String] = []
    #endif

    /// Every pane running an agent, window by window, tab by tab.
    func agents() -> [AgentEntry] {
        workspace.windows.flatMap { window in
            window.tabs.flatMap { tab in
                tab.orderedPanes.compactMap { pane -> AgentEntry? in
                    let state = activity.activity(for: pane.id)
                    guard let program = state.program, program.isAgent else { return nil }
                    let own = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = own.isEmpty || own == pane.workingDirectory ? program.name : own
                    return AgentEntry(pane: pane.id, program: program, title: title, activity: state, project: project(for: activity.agentDirectory(for: pane.id) ?? pane.workingDirectory))
                }
            }
        }
    }

    /// Projects by folder, looked up again after a few seconds (an agent may switch branches).
    private var projects: [String: (project: Project, at: Date)] = [:]

    private func project(for directory: String) -> Project {
        if let cached = projects[directory], Date().timeIntervalSince(cached.at) < 5 { return cached.project }
        let project = Project.find(for: directory, in: DiskFiles())
        projects[directory] = (project, Date())
        return project
    }

    /// A notification was clicked: its pane comes forward, focused.
    func reveal(_ pane: PaneID) {
        guard let (state, tab) = workspace.tab(containing: pane), let controller = controllers[state.id] else { return }
        tab.focus(pane)
        state.select(id: tab.id)
        NSApp.activate()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.reload()
        activity.tick()
        modelDidChange()
    }

    func controller(for id: WindowID) -> TerminalWindowController? { controllers[id] }
    var allControllers: [TerminalWindowController] { Array(controllers.values) }

    func modelDidChange() { onModelChanged?() }

    // MARK: Tint and appearance

    /// Colors a window's chrome from the configured terminal background.
    func applyConfiguredTint(to controller: TerminalWindowController) {
        guard let bg = runtime.configuredBackground else {
            controller.setColors(frame: nil, panel: .textBackgroundColor)
            return
        }
        let color = NSColor(srgbRed: CGFloat(bg.red) / 255, green: CGFloat(bg.green) / 255, blue: CGFloat(bg.blue) / 255, alpha: 1)
        controller.setColors(frame: ChromeTint.frame(forTerminalBackground: color, strength: preferences.settings.tintStrength), panel: color)
    }

    /// Called after every config reload.
    func configDidReload() {
        EditorStyle.update(family: preferences.settings.fontFamily, size: preferences.settings.fontSize)
        EditorStyle.update(foreground: runtime.configuredForeground, palette: runtime.configuredANSIPalette)
        for c in controllers.values {
            applyConfiguredTint(to: c)
            for shell in c.allShells() { shell.styleChanged() }
        }
    }

    /// The system appearance changed: every surface resolves its light/dark theme again.
    func systemAppearanceDidChange(dark: Bool) {
        for c in controllers.values {
            for s in c.allSurfaces() { s.setColorScheme(dark: dark) }
        }
    }

    // MARK: Banner

    private var configBanner: BannerContent?
    /// Bumped per transient banner so an older one's timer does not cut a newer one short.
    private var transientBannerGeneration = 0
    private var transientBanner: BannerContent?

    func showConfigDiagnostics(_ diagnostics: [String]) {
        if diagnostics.isEmpty {
            configBanner = nil
        } else {
            let more = diagnostics.count > 1 ? " (+\(diagnostics.count - 1) more)" : ""
            configBanner = BannerContent(
                message: "Terminal settings: \(diagnostics[0])\(more)",
                actionTitle: "Reset to Defaults",
                action: { [weak self] in self?.preferences.resetToDefaults() }
            )
        }
        applyBanners()
    }

    /// Shows `message` in every window for a few seconds, then restores the settings banner (if any).
    func showTransientBanner(_ message: String) {
        transientBannerGeneration += 1
        let generation = transientBannerGeneration
        transientBanner = BannerContent(message: message)
        applyBanners()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.transientBannerGeneration == generation else { return }
            self.transientBanner = nil
            self.applyBanners()
        }
    }

    private func applyBanners() {
        for c in controllers.values { c.chrome.banner = transientBanner ?? configBanner }
    }

    // MARK: Settings

    func toggleTabLayout() {
        preferences.update { $0.tabLayout = $0.tabLayout == .sidebar ? .strip : .sidebar }
    }

    func toggleTabListHidden() {
        preferences.update { $0.tabListHidden.toggle() }
    }

    private var lastTintStrength: Double?

    /// Applies app-only settings after a change. Layout, sidebar width and visibility are
    /// observed by SwiftUI directly; the model's layout is kept in step for the session file.
    func applyAppSettings(_ settings: Preferences.Settings) {
        let layout = TabLayout(settings.tabLayout)
        if workspace.tabLayout != layout {
            workspace.tabLayout = layout
            modelDidChange()
        }
        if lastTintStrength != settings.tintStrength {
            lastTintStrength = settings.tintStrength
            configDidReload()
        }
        for c in controllers.values { c.focusSelectedPane() }
    }

    // MARK: Windows and tabs

    func newWindow(workingDirectory: String? = nil) {
        let state = workspace.addWindow()
        state.addTab(title: "", workingDirectory: workingDirectory ?? NSHomeDirectory())
        open(state)
        controllers[state.id]?.window?.makeKeyAndOrderFront(nil)
        modelDidChange()
    }

    func newTab(in state: WindowState, workingDirectory: String? = nil) {
        let inherited = preferences.settings.newTabDirectory == .currentPane ? state.selectedTab?.workingDirectory : nil
        let dir = workingDirectory ?? inherited ?? NSHomeDirectory()
        state.addTab(title: "", workingDirectory: dir)
        controllers[state.id]?.reload()
        modelDidChange()
    }

    func select(_ id: TabID) {
        guard let state = workspace.window(containing: id) else { return }
        state.select(id: id)
        controllers[state.id]?.reload()
        modelDidChange()
    }

    /// Closes a tab and all its panes; closing the last tab closes the window. A pinned tab is
    /// not closed: it is unpinned first.
    func closeTab(_ id: TabID) {
        guard let state = workspace.window(containing: id), let controller = controllers[state.id],
              let tab = state.tab(id: id) else { return }
        guard tab.pin == nil else {
            NSSound.beep()
            return
        }
        for pane in tab.orderedPanes { controller.removeSurface(for: pane.id) }
        state.closeTab(id: id)
        if state.isEmpty {
            controller.window?.close()
        } else {
            controller.reload()
        }
        modelDidChange()
    }

    func rename(_ id: TabID, to title: String) {
        guard let state = workspace.window(containing: id), let tab = state.tab(id: id) else { return }
        tab.customTitle = title
        controllers[state.id]?.reload()
        modelDidChange()
    }

    func move(_ id: TabID, to index: Int) {
        guard let state = workspace.window(containing: id) else { return }
        state.moveTab(id: id, to: index)
        controllers[state.id]?.reload()
        modelDidChange()
    }

    // MARK: Pinned tabs

    /// Pins a tab with the folder of its focused pane and the command running there, if any.
    /// `index` places it among the pinned tabs (a drop); nil adds it after them.
    func pin(_ id: TabID, at index: Int? = nil) {
        guard let state = workspace.window(containing: id), let controller = controllers[state.id],
              let tab = state.tab(id: id) else { return }
        if tab.pin != nil {
            if let index { state.moveTab(id: id, to: index) }
        } else {
            let pane = tab.focusedPaneID
            let shell = controller.shell(for: pane)
            let running = activity.activity(for: pane).isRunning || shell?.phase == .running
            // The program in front, not the shell itself (`-zsh`).
            let arguments = controller.existingSurface(for: pane)?.foregroundPID
                .flatMap { pid in running && pid > 0 && pid != shell?.state.shellPID ? ProcessArguments.read(pid: Int32(pid))?.arguments : nil }
            let command = PinnedCommand.capture(running: running, lastCommand: shell?.lastCommand, arguments: arguments)
            state.pin(id, TabPin(directory: tab.workingDirectory, command: command), at: index)
        }
        controller.reload()
        modelDidChange()
    }

    /// `index` places it among the other tabs (a drop); nil puts it first after the pinned tabs.
    func unpin(_ id: TabID, at index: Int? = nil) {
        guard let state = workspace.window(containing: id), let tab = state.tab(id: id) else { return }
        if tab.pin == nil {
            if let index { state.moveTab(id: id, to: index) }
        } else {
            state.unpin(id, at: index)
        }
        controllers[state.id]?.reload()
        modelDidChange()
    }

    func setPinnedIcon(_ id: TabID, _ icon: PinIcon?) {
        guard let state = workspace.window(containing: id) else { return }
        state.setPinnedIcon(id, icon)
        modelDidChange()
    }

    func setPinnedCommand(_ id: TabID, _ command: String?) {
        guard let state = workspace.window(containing: id) else { return }
        state.setPinnedCommand(id, command)
        modelDidChange()
    }

    /// When each pinned tab's shell was last restarted on its own.
    private var automaticRestarts: [TabID: Date] = [:]

    /// A pinned tab's only shell exited (or could not start): a fresh one takes its place, unless
    /// the last one also ended within seconds. Then the pane stays, exited, for the user to
    /// restart, so a shell that cannot run never loops.
    private func restartAfterExit(_ id: TabID, pane: PaneID, in controller: TerminalWindowController) {
        let now = Date()
        if let last = automaticRestarts[id], now.timeIntervalSince(last) < 5 {
            if controller.chrome.exitedPanes[pane] == nil { controller.chrome.exitedPanes[pane] = 1 }
            return
        }
        automaticRestarts[id] = now
        resetPinned(id, runningCommand: false)
    }

    /// Takes a pinned tab back to its pin: one fresh shell in the pinned folder, running the
    /// pinned command when `runningCommand` (not after its shell exited: the user ended it).
    func resetPinned(_ id: TabID, runningCommand: Bool) {
        guard let state = workspace.window(containing: id), let controller = controllers[state.id],
              let tab = state.tab(id: id), let pin = tab.pin else { return }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: pin.directory, isDirectory: &isDirectory) && isDirectory.boolValue
        let removed = tab.reset(workingDirectory: exists ? pin.directory : NSHomeDirectory(),
                                startupCommand: runningCommand && exists ? pin.command : nil)
        for pane in removed { controller.removeSurface(for: pane) }
        controller.reload()
        modelDidChange()
    }

    func windowWillClose(_ id: WindowID) {
        guard let controller = controllers.removeValue(forKey: id) else { return }
        for view in controller.allSurfaces() { view.teardown() }
        controller.stopShells()
        workspace.removeWindow(id: id)
        modelDidChange()
    }

    private func open(_ state: WindowState) {
        let controller = TerminalWindowController(state: state, coordinator: self, runtime: runtime)
        controllers[state.id] = controller
        controller.chrome.banner = transientBanner ?? configBanner
        applyConfiguredTint(to: controller)
        controller.reload()
        controller.showWindow(nil)
    }

    // MARK: Panes

    func split(_ pane: PaneID, direction: SplitDirection) {
        guard let (state, tab) = workspace.tab(containing: pane), let controller = controllers[state.id],
              let source = tab.pane(pane) else { return }
        let new = tab.split(pane, direction: direction, workingDirectory: source.workingDirectory)
        controller.prepareSplit(new.id, inheritingFrom: pane)
        state.select(id: tab.id)
        controller.reload()
        modelDidChange()
    }

    /// Removes a pane (its surface is already closing or closed); the last pane closes its tab.
    /// A pinned tab's last pane is replaced instead: its shell exited, and a fresh one starts in
    /// the pinned folder.
    func closePane(_ pane: PaneID) {
        guard let (state, tab) = workspace.tab(containing: pane), let controller = controllers[state.id] else { return }
        guard tab.hasSplits else {
            if tab.pin != nil {
                restartAfterExit(tab.id, pane: pane, in: controller)
            } else {
                closeTab(tab.id)
            }
            return
        }
        controller.removeSurface(for: pane, closingOutOf: tab.id)
        tab.closePane(pane)
        controller.reload()
        modelDidChange()
    }

    /// The user clicked into (or programmatically focused) a pane's terminal.
    func paneDidFocus(_ pane: PaneID) {
        guard let (state, tab) = workspace.tab(containing: pane), tab.focusedPaneID != pane || state.selectedTabID != tab.id else { return }
        tab.focus(pane)
        if state.selectedTabID != tab.id { state.select(id: tab.id) }
        controllers[state.id]?.reload()
        modelDidChange()
    }

    func movePane(_ pane: PaneID, to target: PaneID, edge: PaneEdge) {
        guard let (sourceWindow, _) = workspace.tab(containing: pane),
              let (targetWindow, _) = workspace.tab(containing: target) else { return }
        guard workspace.movePane(pane, to: target, edge: edge) else { return }
        finishMove(pane, from: sourceWindow, to: targetWindow)
    }

    func movePane(_ pane: PaneID, intoTab tabID: TabID) {
        guard let (sourceWindow, _) = workspace.tab(containing: pane),
              let targetWindow = workspace.window(containing: tabID) else { return }
        guard workspace.movePane(pane, intoTab: tabID) else { return }
        finishMove(pane, from: sourceWindow, to: targetWindow)
    }

    /// After a model move: hand the live surface to the target window if it changed, close a
    /// window left without tabs, and focus the moved pane.
    private func finishMove(_ pane: PaneID, from source: WindowState, to target: WindowState) {
        if source !== target, let from = controllers[source.id], let to = controllers[target.id],
           let (surface, shell) = from.relinquishSurface(for: pane) {
            to.adoptSurface(surface, shell: shell, for: pane)
        }
        if source.isEmpty {
            controllers[source.id]?.window?.close()
        } else {
            controllers[source.id]?.reload()
        }
        if let to = controllers[target.id] {
            to.reload()
            if source !== target { to.window?.makeKeyAndOrderFront(nil) }
        }
        modelDidChange()
    }

    // MARK: Lookup

    private func locate(_ view: TerminalSurfaceView) -> (WindowState, Tab, Pane, TerminalWindowController)? {
        guard let id = view.token?.base as? PaneID,
              let (state, tab) = workspace.tab(containing: id),
              let pane = tab.pane(id),
              let controller = controllers[state.id] else { return nil }
        return (state, tab, pane, controller)
    }

    private var keyWindowState: WindowState? {
        controllers.values.first { $0.window?.isKeyWindow == true }?.state ?? workspace.windows.first
    }

    // MARK: GhosttyActionSink

    func handle(_ action: GhosttyAction, target: GhosttyActionTarget) -> Bool {
        let located: (WindowState, Tab, Pane, TerminalWindowController)?
        if case .surface(let view) = target { located = locate(view) } else { located = nil }
        let state = located?.0 ?? keyWindowState

        switch action {
        case .newWindow:
            newWindow(workingDirectory: located?.2.workingDirectory)
            return true
        case .newTab:
            guard let state else { return false }
            newTab(in: state)
            return true
        case .closeTab(let mode):
            guard let state else { return false }
            let selected = located?.1.id ?? state.selectedTabID
            guard let selected else { return false }
            switch mode {
            case .this: closeTab(selected)
            case .others: state.tabs.map(\.id).filter { $0 != selected }.forEach(closeTab)
            case .right:
                guard let i = state.index(of: selected) else { return false }
                state.tabs.dropFirst(i + 1).map(\.id).forEach(closeTab)
            }
            return true
        case .closeWindow:
            guard let state else { return false }
            controllers[state.id]?.window?.performClose(nil)
            return true
        case .quit:
            NSApp.terminate(nil)
            return true
        case .gotoTab(let g):
            guard let state else { return false }
            let target: GotoTabTarget
            switch g {
            case .index(let n): target = .index(n)
            case .previous: target = .previous
            case .next: target = .next
            case .last: target = .last
            }
            let moved = state.gotoTab(target)
            if moved { controllers[state.id]?.reload(); modelDidChange() }
            return moved
        case .moveTab(let amount):
            guard let state else { return false }
            let moved = state.moveSelectedTab(by: amount)
            if moved { controllers[state.id]?.reload(); modelDidChange() }
            return moved
        case .setTitle(let title), .setTabTitle(let title):
            guard let located else { return false }
            located.2.title = title
            located.3.reload()
            return true
        case .pwd(let dir):
            guard let located else { return false }
            // The integration's ready signal is a report under a reserved path, not a directory.
            if located.3.shell(for: located.2.id)?.directoryReported(dir) == true { return true }
            located.2.workingDirectory = dir
            located.3.reload()
            modelDidChange()
            return true
        case .initialSize(let w, let h):
            guard let located else { return false }
            located.3.applyInitialTerminalSize(CGSize(width: Double(w), height: Double(h)))
            return true
        case .cellSize, .render, .configChange:
            return true
        case .colorChange(let kind, let r, let g, let b):
            // Only the focused pane of the selected tab (OSC 11) tints its own window.
            guard kind == .background, let located, located.0.selectedTabID == located.1.id,
                  located.1.focusedPaneID == located.2.id else { return false }
            let color = NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            located.3.setColors(frame: ChromeTint.frame(forTerminalBackground: color, strength: preferences.settings.tintStrength), panel: color)
            return true
        case .showChildExited(let code, _):
            guard let located else { return false }
            located.3.chrome.exitedPanes[located.2.id] = code
            return true
        case .closeSurface(let processAlive):
            guard let located else { return false }
            let paneID = located.2.id
            if processAlive, preferences.settings.confirmCloseRunning {
                let message = located.1.hasSplits ? "Close this pane?" : "Close this tab?"
                located.3.confirmClose(message: message, informativeText: "A process is still running in it.") { [weak self] in
                    self?.closePane(paneID)
                }
            } else {
                closePane(paneID)
            }
            return true
        case .desktopNotification(let title, let body):
            // A program (an agent waiting for the user) asks for attention: marked and notified
            // where the user is not looking; where they are, they see it already.
            guard let located else {
                Notifications.post(title: title.isEmpty ? "PrompTTY" : title, body: body, pane: nil)
                return true
            }
            activity.attention(located.2.id, message: [title, body].filter { !$0.isEmpty }.joined(separator: ": "))
            return true
        case .ringBell:
            if let located, activity.attention(located.2.id, message: nil) { return true }
            NSSound.beep()
            return true
        case .commandFinished(let code, let duration):
            guard let located else { return false }
            activity.exitReported(located.2.id, code: Int(code))
            located.3.shell(for: located.2.id)?.commandFinished(code: code, durationNs: duration)
            return true
        case .reloadConfig, .openConfig, .mouseShape, .mouseVisibility, .unhandled:
            // Config, mouse-shape and mouse-visibility actions are handled by the runtime.
            return false
        }
    }
}

#if DEBUG
extension WorkspaceCoordinator {
    /// One line per window, tab and pane, for the debug driver.
    func debugState() -> String {
        var lines = ["layout=\(workspace.tabLayout.rawValue) hidden=\(preferences.settings.tabListHidden) windows=\(workspace.windows.count)"]
        for (wi, w) in workspace.windows.enumerated() {
            lines.append("window \(wi) tabs=\(w.tabs.count) selected=\(w.selectedTabID.flatMap(w.index(of:)).map(String.init) ?? "-")")
            for (ti, t) in w.tabs.enumerated() {
                lines.append("  tab \(ti) title=\"\(t.displayTitle)\" dir=\(t.abbreviatedDirectory) panes=\(t.panes.count) tree=\(describe(t.root, t))")
            }
        }
        if let key = controllers.values.first(where: { $0.window?.isKeyWindow == true }) ?? controllers.values.first,
           let surface = key.window?.firstResponder as? TerminalSurfaceView,
           let id = surface.token?.base as? PaneID, let (_, tab) = workspace.tab(containing: id) {
            lines.append("firstResponder=pane\(tab.root.leaves.firstIndex(of: id).map(String.init) ?? "?") of tab \"\(tab.displayTitle)\"")
        }
        return lines.joined(separator: "\n")
    }

    private func describe(_ node: SplitNode, _ tab: Tab) -> String {
        switch node {
        case .leaf(let id):
            let index = tab.root.leaves.firstIndex(of: id).map(String.init) ?? "?"
            return id == tab.focusedPaneID ? "[p\(index)*]" : "[p\(index)]"
        case .split(let axis, let ratio, let a, let b):
            return "(\(axis == .horizontal ? "H" : "V") \(String(format: "%.2f", ratio)) \(describe(a, tab)) \(describe(b, tab)))"
        }
    }
}
#endif
