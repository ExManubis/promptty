import AgentHooks
import AppKit
import Carbon.HIToolbox
import CommandBlocks
import CommandEditing
import GhosttyBridge
import Observation
import PaneActivity
import RemoteControl
import Preferences
import UniformTypeIdentifiers
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
    /// macOS secure keyboard input: forced by the menu, or asked for by a pane at a password prompt.
    let secureInput = SecureInputOwner<PaneID>(
        appActive: NSApp.isActive,
        enable: { EnableSecureEventInput() == noErr },
        disable: { DisableSecureEventInput() == noErr }
    )
    /// Schedules a session save.
    var onModelChanged: (() -> Void)?

    init(runtime: GhosttyRuntime, workspace: Workspace, preferences: PreferencesController) {
        self.runtime = runtime
        self.workspace = workspace
        self.preferences = preferences
        lastAppSettings = preferences.settings
        activity.panes = { [weak self] in self?.watchedPanes() ?? [] }
        activity.isSeen = { [weak self] in self?.isSeen($0) ?? false }
        activity.onNotice = { [weak self] pane, notice in self?.post(notice, for: pane) }
        activity.onSeen = { Notifications.remove(for: $0) }
        activity.allPanes = { [weak self] in Set(self?.allPaneIDs ?? []) }
        activity.afterTick = { [weak self] in self?.lookUpRepositories() }
        secureInput.global = preferences.settings.secureKeyboardEntry
        activity.marksUnseenOutput = preferences.settings.markUnseenOutput
        ChromeTint.opacity = CGFloat(preferences.settings.windowOpacity)
        secureInput.onChange = { [weak self] in self?.refreshSecureIndicators() }
    }

    /// Every pane's lock follows the owner: shown on a pane that asked for secure input itself, or
    /// on all of them while the menu forces it.
    func refreshSecureIndicators() {
        for pane in allPaneIDs {
            activity.status(for: pane).setSecure(secureInput.isSecure(pane))
        }
    }

    /// Every pane, window by window, tab by tab.
    private var allPaneIDs: [PaneID] { workspace.windows.flatMap(\.paneIDs) }

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
        startHooks()
        startControl()
        refreshAgents()
    }

    /// Listens for agents' hooks (`promptty-hook`, run by Claude Code inside a pane). Without the
    /// socket, agents are still followed by their screens.
    private func startHooks() {
        // Delivered on the main queue.
        let listener = HookListener(path: AppPaths.hookSocket) { [weak self] message in
            MainActor.assumeIsolated { self?.activity.hookMessage(message) }
        }
        do {
            try listener.start()
            hookListener = listener
        } catch HookListener.Failure.inUse {
            // Another PrompTTY on the same data folder: its panes' hooks are its own.
            NSLog("PrompTTY: another app listens at \(AppPaths.hookSocket); hooks go there")
        } catch {
            NSLog("PrompTTY: no hook socket at \(AppPaths.hookSocket): \(error)")
        }
    }

    private var hookListener: HookListener?

    /// Takes the hook socket away (at quit).
    func stopHooks() {
        hookListener?.stop()
        hookListener = nil
        controlServer?.stop()
        controlServer = nil
    }

    private var controlServer: ControlServer?
    /// `promptty wait`: replies waiting for a command to end, or for its pane to close.
    var commandWaiters = CommandWaiters<PaneID>()
    /// Ids handed out for a command before its pane's shell runs it, and that pane.
    var pendingCommands: [String: (pane: PaneID, command: String)] = [:]

    /// Listens for `promptty`. Requests are answered on the main thread.
    func startControl() {
        let server = ControlServer(path: AppPaths.controlSocket) { [weak self] request, reply in
            MainActor.assumeIsolated {
                guard let self else { return reply(.failed("PrompTTY is quitting")) }
                self.handleControl(request, reply: reply)
            }
        }
        do {
            try server.start()
            controlServer = server
        } catch {
            NSLog("PrompTTY: no control socket at \(AppPaths.controlSocket): \(error)")
        }
    }

    // MARK: Activity

    /// Whether the user looks at a window: the app in front, the window main and on screen. Main,
    /// not key: a sheet, a picker's popover or the Settings window can have the keys while the
    /// user looks at this window.
    private func isSeen(_ window: NSWindow?) -> Bool {
        NSApp.isActive && window?.isMainWindow == true && window?.occlusionState.contains(.visible) == true
    }

    /// Whether the user sees one pane: its tab selected in a window they look at, and not hidden
    /// behind another pane's zoom.
    private func isSeen(_ pane: PaneID) -> Bool {
        guard let (state, tab) = workspace.tab(containing: pane), let controller = controllers[state.id] else { return false }
        return controller.state.selectedTabID == tab.id && tab.isShown(pane) && isSeen(controller.window)
    }

    /// Every pane with a terminal, and whether the user sees it. Built once per tick, so the pids
    /// are read lazily: only for the panes whose checks are due.
    private func watchedPanes() -> [ActivityTracker.Watched] {
        var watched: [ActivityTracker.Watched] = []
        for controller in controllers.values {
            let window = controller.window
            let windowSeen = isSeen(window)
            let windowVisible = window?.occlusionState.contains(.visible) == true
            for tab in controller.state.tabs {
                let selected = controller.state.selectedTabID == tab.id
                for pane in tab.orderedPanes {
                    guard let surface = controller.existingSurface(for: pane.id) else { continue }
                    let id = pane.id
                    // A pane hidden behind another's zoom is not looked at.
                    let shown = selected && tab.isShown(id)
                    watched.append(ActivityTracker.Watched(
                        pane: id,
                        foregroundPID: { [weak surface] in surface?.foregroundPID },
                        shellPID: { [weak controller] in controller?.shell(for: id)?.state.shellPID },
                        visible: windowVisible && shown,
                        seen: windowSeen && shown,
                        checkShell: { [weak controller] in controller?.shell(for: id)?.checkForeground() },
                        screen: { [weak surface] in surface?.activeScreenText() },
                        quietUntil: [surface.lastResize.map { $0.addingTimeInterval(1.5) },
                                     surface.lastKeyPress.map { $0.addingTimeInterval(1) }].compactMap { $0 }.max(),
                        lastAnswerKey: surface.lastAnswerKey
                    ))
                }
            }
        }
        return watched
    }

    private func post(_ notice: Notice, for pane: PaneID) {
        guard let (state, tab) = workspace.tab(containing: pane) else { return }
        switch notice.kind {
        case .finished, .failed:
            let settings = preferences.settings
            guard settings.notifyCommands, (notice.duration ?? 0) >= settings.notifyAfterSeconds else { return }
        default: break
        }
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

    /// The agents of every tab, in every window, for the sidebars' tab rows.
    let agentList = AgentList()
    private var agentsScheduled = false
    /// The folders the agents work in, as the list last found them.
    private var agentFolders: Set<String> = []
    private var repositories = RepositoryCache()

    /// The list is worked out again on the next turn of the run loop: changes made together are
    /// one update.
    private func scheduleAgents() {
        guard !agentsScheduled else { return }
        agentsScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refreshAgents() }
        }
    }

    /// Works the agents out, watching what that read (the windows, tabs and panes, the panes'
    /// folders, what runs in each), and publishes them when they changed.
    private func refreshAgents() {
        agentsScheduled = false
        let tabs = withObservationTracking { agentSummaries() } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleAgents() } }
        }
        agentList.update(tabs, liveTabs: Set(workspace.windows.flatMap { $0.tabs.map(\.id) }))
        lookUpRepositories()
    }

    /// Each tab's most urgent agent, and how many others it has.
    private func agentSummaries() -> [TabID: TabAgentSummary] {
        var folders = Set<String>()
        var summaries: [TabID: TabAgentSummary] = [:]
        for window in workspace.windows {
            for tab in window.tabs {
                let entries = tab.orderedPanes.compactMap { pane -> AgentEntry? in
                    let status = activity.status(for: pane.id)
                    guard let program = status.activity.program, program.isAgent else { return nil }
                    // The agent's own folder: it may differ from the shell's (`cd x && claude`).
                    let folder = activity.agentDirectory(for: pane.id) ?? pane.workingDirectory
                    folders.insert(folder)
                    return AgentEntry(pane: pane.id, display: status.activity.display,
                                      repository: repositories.repository(for: folder) ?? Repository(root: folder, branch: nil),
                                      status: status)
                }
                guard let shown = AgentListing.mostUrgent(entries.map { ($0.pane, $0.display) }, focused: tab.focusedPaneID),
                      let entry = entries.first(where: { $0.pane == shown }) else { continue }
                summaries[tab.id] = TabAgentSummary(entry: entry, others: entries.count - 1)
            }
        }
        agentFolders = folders
        return summaries
    }

    /// Looks up the repositories of the agents' folders off the main thread: new folders at once,
    /// the others again every few seconds (an agent may switch branches). Called after every
    /// activity tick too, while a window is on screen.
    private func lookUpRepositories() {
        for folder in repositories.due(agentFolders, at: Date()) {
            Task.detached(priority: .utility) { [weak self] in
                let repository = Repository.find(for: folder, in: DiskFiles())
                await self?.found(repository, for: folder)
            }
        }
    }

    private func found(_ repository: Repository, for folder: String) {
        if repositories.resolved(folder, repository, at: Date()) { scheduleAgents() }
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
    /// The window a pane is in, with its controller.
    func controller(containing pane: PaneID) -> TerminalWindowController? {
        workspace.tab(containing: pane).flatMap { controllers[$0.0.id] }
    }
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
        EditorStyle.cursor = preferences.cursorColor
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

    private var lastAppSettings: Preferences.Settings

    /// Applies app-only settings after a change. Layout, sidebar width and visibility are
    /// observed by SwiftUI directly; the model's layout is kept in step for the session file.
    /// Dragging the Frame color or Opacity slider changes settings at every step, so a change to
    /// only those recolors the chrome and touches nothing else.
    func applyAppSettings(_ settings: Preferences.Settings) {
        let old = lastAppSettings
        lastAppSettings = settings
        if old.tintStrength != settings.tintStrength || old.windowOpacity != settings.windowOpacity {
            ChromeTint.opacity = CGFloat(settings.windowOpacity)
            for c in controllers.values { applyConfiguredTint(to: c) }
        }
        var rest = old
        rest.tintStrength = settings.tintStrength
        rest.windowOpacity = settings.windowOpacity
        if rest == settings { return }
        activity.marksUnseenOutput = settings.markUnseenOutput
        let layout = TabLayout(settings.tabLayout)
        if workspace.tabLayout != layout {
            workspace.tabLayout = layout
            modelDidChange()
        }
        if secureInput.global != settings.secureKeyboardEntry {
            secureInput.global = settings.secureKeyboardEntry
            refreshSecureIndicators()
        }
        for c in controllers.values {
            c.focusSelectedPane()
            c.updateRefreshRate()
        }
    }

    /// The app came to the front or left it: windows ask for the full refresh rate only while
    /// it is in front.
    func appActivationChanged() {
        for c in controllers.values { c.updateRefreshRate() }
        secureInput.setAppActive(NSApp.isActive)
    }

    // MARK: Windows and tabs

    func newWindow(workingDirectory: String? = nil) {
        let state = workspace.addWindow()
        state.addTab(title: "", workingDirectory: workingDirectory ?? NSHomeDirectory())
        open(state)
        controllers[state.id]?.window?.makeKeyAndOrderFront(nil)
        modelDidChange()
    }

    /// A new tab, in the selected tab's project (if it has one) unless `inheritingProject` is off.
    func newTab(in state: WindowState, workingDirectory: String? = nil, inheritingProject: Bool = true) {
        let inherited = preferences.settings.newTabDirectory == .currentPane ? state.selectedTab?.workingDirectory : nil
        let dir = workingDirectory ?? inherited ?? NSHomeDirectory()
        let project = inheritingProject ? state.selectedTab.flatMap(state.project(of:)) : nil
        state.addTab(title: "", workingDirectory: dir, project: project)
        controllers[state.id]?.reload()
        modelDidChange()
    }

    /// A new tab, after the selected one, running `command` at its first prompt (typed ahead into
    /// a shell without the integration).
    @discardableResult
    func newTab(in state: WindowState, running command: String?, workingDirectory: String? = nil, commandID: String? = nil) -> PaneID {
        let project = state.selectedTab.flatMap(state.project(of:))
        let tab = state.addTab(title: "", workingDirectory: workingDirectory ?? NSHomeDirectory(), project: project)
        tab.focusedPane.startupCommand = command
        tab.focusedPane.startupBlockID = commandID
        controllers[state.id]?.reload()
        modelDidChange()
        return tab.focusedPaneID
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
        if let closed = state.closedTab(tab) { closedTabs.push(closed) }
        for pane in tab.orderedPanes { controller.removeSurface(for: pane.id) }
        panesClosed(tab.orderedPanes.map(\.id))
        state.closeTab(id: id)
        if state.isEmpty {
            controller.window?.close()
        } else {
            controller.reload()
        }
        modelDidChange()
    }

    /// At quit: writes what each tab's focused pane shows to the scrollback archive, and returns the
    /// file kept for each tab. A restored tab never shown keeps the file it came with. Nothing
    /// (and no files) when the setting is off.
    func archiveScrollback() -> [TabID: String] {
        let archive = ScrollbackArchive(directory: AppPaths.scrollback)
        let settings = preferences.settings
        guard settings.restoreSession, settings.restoreScrollback else {
            archive.clear()
            return [:]
        }
        let now = Date()
        var texts: [String: String] = [:]
        var kept = Set<String>()
        var names: [TabID: String] = [:]
        for state in workspace.windows {
            guard let controller = controllers[state.id] else { continue }
            for tab in state.tabs {
                let pane = tab.focusedPane
                if let surface = controller.surfaces[pane.id] {
                    guard let text = surface.allText(styled: true),
                          let archived = ScrollbackArchive.archived(text, savedAt: now) else { continue }
                    let name = "\(tab.id.rawValue.uuidString).vt"
                    texts[name] = archived
                    names[tab.id] = name
                } else if let pending = pane.restoredScrollback {
                    kept.insert(pending)
                    names[tab.id] = pending
                }
            }
        }
        archive.replace(with: texts, keeping: kept)
        lastArchive = names
        return names
    }

    private var lastArchive: [TabID: String] = [:]

    /// The archive files written last, for a session saved in between: each tab's, or the one a
    /// restored tab came with (until its shell prints it).
    var archivedScrollback: [TabID: String] {
        guard preferences.settings.restoreSession, preferences.settings.restoreScrollback else { return [:] }
        var names: [TabID: String] = [:]
        for state in workspace.windows {
            for tab in state.tabs {
                if let name = lastArchive[tab.id] ?? tab.focusedPane.restoredScrollback { names[tab.id] = name }
            }
        }
        return names
    }

    /// The drop-down terminal on the global shortcut; set by the app delegate.
    var quickTerminal: QuickTerminal? {
        didSet {
            quickTerminal?.onShortcutUnavailable = { [weak self] shortcut in
                self?.showTransientBanner("The quick terminal's shortcut \(shortcut) is taken by another app. Choose another in Settings › Keyboard.")
            }
        }
    }

    /// The tabs closed most recently, for Reopen Closed Tab.
    private(set) var closedTabs = ClosedTabStack()

    /// Opens the most recently closed tab again: in its window if that is still open, else in
    /// `fallback`'s.
    func reopenClosedTab(fallback: WindowState?) {
        guard let closed = closedTabs.pop() else { return NSSound.beep() }
        guard let state = workspace.windows.first(where: { $0.id == closed.window }) ?? fallback ?? workspace.windows.first,
              let controller = controllers[state.id] else { return }
        state.reopen(closed, projectExists: { [workspace] in workspace.project(id: $0) != nil },
                     directoryExists: { path in
                         var isDirectory: ObjCBool = false
                         return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                     })
        controller.reload()
        controller.window?.makeKeyAndOrderFront(nil)
        modelDidChange()
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    /// Labels a pane (an empty label takes it away).
    func setLabel(_ text: String, of pane: PaneID) {
        guard let (state, tab) = workspace.tab(containing: pane), let target = tab.pane(pane) else { return }
        target.label = Pane.label(text)
        controllers[state.id]?.reload()
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
            let running = activity.state(for: pane).isRunning || shell?.phase == .running
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

    // MARK: Projects

    /// The name a new project from `tab` suggests: its repository's (or folder's).
    func suggestedProjectName(for tab: TabID?) -> String {
        guard let tab, let state = workspace.window(containing: tab), let directory = state.tab(id: tab)?.workingDirectory else {
            return Project.untitled
        }
        let name = (Repository.find(for: directory, in: DiskFiles()).root as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? Project.untitled : name
    }

    /// Makes a project and moves `tab` (in any window) into it.
    func addProject(name: String, adding tab: TabID?) {
        let project = workspace.addProject(name: name)
        if let tab, let state = workspace.window(containing: tab) {
            state.setProject(tab, project.id)
            controllers[state.id]?.reload()
        }
        modelDidChange()
    }

    /// A tab in the project, in the folder of the project's selected tab (or its last one in the
    /// window); a project without tabs here opens it where ⌘T would.
    func newTab(in state: WindowState, project id: ProjectID) {
        guard let project = workspace.project(id: id) else { return }
        if project.folded { project.folded = false }
        let inProject = state.tabs.filter { state.project(of: $0) == id }
        let source = inProject.first { $0.id == state.selectedTabID } ?? inProject.last
        let usual = preferences.settings.newTabDirectory == .currentPane ? state.selectedTab?.workingDirectory : nil
        state.addTab(title: "", workingDirectory: source?.workingDirectory ?? usual ?? NSHomeDirectory(), project: id)
        controllers[state.id]?.reload()
        modelDidChange()
    }

    func placeTab(_ id: TabID, inProject project: ProjectID?, at index: Int?) {
        guard let state = workspace.window(containing: id), let tab = state.tab(id: id) else { return }
        if tab.pin != nil, index != nil { state.unpin(id) }
        state.setProject(id, project, at: index)
        controllers[state.id]?.reload()
        modelDidChange()
    }

    /// A blank name keeps the old one.
    func renameProject(_ id: ProjectID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let project = workspace.project(id: id), !trimmed.isEmpty else { return }
        project.name = trimmed
        modelDidChange()
    }

    func setProjectIcon(_ id: ProjectID, _ icon: PinIcon?) {
        workspace.project(id: id)?.icon = icon
        modelDidChange()
    }

    func setProjectFolded(_ id: ProjectID, _ folded: Bool) {
        guard let project = workspace.project(id: id), project.folded != folded else { return }
        project.folded = folded
        modelDidChange()
    }

    func moveProject(_ id: ProjectID, by offset: Int) {
        guard let from = workspace.projects.firstIndex(where: { $0.id == id }) else { return }
        moveProject(id, to: from + offset)
    }

    func moveProject(_ id: ProjectID, to index: Int) {
        guard workspace.project(id: id) != nil else { return }
        workspace.moveProject(id: id, to: index)
        for c in controllers.values { c.reload() }
        modelDidChange()
    }

    /// How many tabs, in every window, are in the project.
    func tabCount(inProject id: ProjectID) -> Int {
        workspace.windows.reduce(0) { count, window in count + window.tabs.filter { $0.projectID == id }.count }
    }

    func removeProject(_ id: ProjectID) {
        workspace.removeProject(id: id)
        for c in controllers.values { c.reload() }
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
        panesClosed(removed)
        controller.reload()
        modelDidChange()
    }

    func windowWillClose(_ id: WindowID) {
        guard let controller = controllers.removeValue(forKey: id) else { return }
        // Before the surfaces are freed: a freed one reports no more, and a pane left in the owner
        // would hold secure input on for the whole system.
        if let state = workspace.windows.first(where: { $0.id == id }) {
            secureInput.remove(state.paneIDs)
        }
        for view in controller.allSurfaces() { view.teardown() }
        controller.stopShells()
        if let state = workspace.windows.first(where: { $0.id == id }) { panesClosed(state.paneIDs) }
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

    /// Splits `pane`; the new pane opens in `workingDirectory` (else the pane's) and runs
    /// `command` at its first prompt. Returns it.
    @discardableResult
    func split(_ pane: PaneID, direction: SplitDirection, workingDirectory: String? = nil, command: String? = nil,
               commandID: String? = nil) -> PaneID? {
        guard let (state, tab) = workspace.tab(containing: pane), let controller = controllers[state.id],
              let source = tab.pane(pane) else { return nil }
        let new = tab.split(pane, direction: direction, workingDirectory: workingDirectory ?? source.workingDirectory)
        new.startupCommand = command
        new.startupBlockID = commandID
        controller.prepareSplit(new.id, inheritingFrom: pane)
        state.select(id: tab.id)
        controller.reload()
        modelDidChange()
        return new.id
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
        panesClosed([pane])
        tab.closePane(pane)
        controller.reload()
        modelDidChange()
    }

    /// The user clicked into (or programmatically focused) a pane's terminal or input bar.
    func paneDidFocus(_ pane: PaneID) {
        guard let (state, tab) = workspace.tab(containing: pane) else { return }
        // Panes out of sight (another tab, or behind a zoom) take no clicks, but AppKit can still
        // hand them the keys: their input bars are only transparent, so one can be the next key
        // view when the view with the keys is hidden. That must not switch tabs (or unzoom) under
        // the user: the keys go back where they belong.
        guard state.selectedTabID == tab.id, tab.isShown(pane) else {
            controllers[state.id]?.focusSelectedPane()
            return
        }
        guard tab.focusedPaneID != pane else { return }
        tab.focus(pane)
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

    // MARK: Links

    /// Carries out what `LinkTarget` decided; a refusal or a failure beeps. Nothing is ever run.
    private func openLink(_ decision: LinkDecision) {
        switch decision {
        case .open(let url):
            if !NSWorkspace.shared.open(url) { NSSound.beep() }
        case .openAsText(let url):
            guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { NSSound.beep() }
            }
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .confirm(let url):
            let alert = NSAlert()
            alert.messageText = "Open this link?"
            alert.informativeText = url.absoluteString
            // The first button is the default one.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open")
            if alert.runModal() == .alertSecondButtonReturn, !NSWorkspace.shared.open(url) { NSSound.beep() }
        case .refuse:
            NSSound.beep()
        }
    }

    /// The clipboard policy may have changed: requests asked under the old one are refused.
    func denyClipboardRequests() {
        for controller in controllers.values { controller.denyClipboardRequests() }
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
        // The quick terminal is no pane: it closes itself and copes with nothing else.
        if case .surface(let view) = target, view.token?.base is QuickTerminal.Token {
            switch action {
            case .closeSurface, .showChildExited:
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.quickTerminal?.surfaceClosed() } }
                return true
            case .scrollbar, .cellSize, .render, .mouseOverLink, .initialSize:
                return true
            default:
                return false
            }
        }
        // The screen moved in the scrollback, the scrollback grew, or rows changed height: the
        // command blocks moved. These arrive constantly in a stream, so no `locate` for them.
        switch action {
        case .scrollbar(let total, _, _):
            if case .surface(let view) = target {
                view.onLayoutChange?()
                if let pane = view.token?.base as? PaneID { activity.rowsReported(pane, total: total) }
            }
            return true
        case .cellSize:
            if case .surface(let view) = target { view.onLayoutChange?() }
            return true
        case .mouseOverLink(let link):
            // On every mouse move over text, so straight to the pane's card.
            if case .surface(let view) = target { view.onLinkHover?(link) }
            return true
        case .progressReport(let state, let percent):
            // Often while a program runs, so straight to the pane's box.
            guard case .surface(let view) = target, let pane = view.token?.base as? PaneID else { return false }
            let kind: PaneProgress.Kind?
            switch state {
            case .remove: kind = nil
            case .set: kind = .set
            case .error: kind = .error
            case .indeterminate: kind = .indeterminate
            case .pause: kind = .pause
            }
            activity.reportProgress(pane, kind: kind, percent: percent)
            return true
        case .startSearch(let needle):
            guard case .surface(let view) = target, let pane = view.token?.base as? PaneID else { return false }
            let status = activity.status(for: pane)
            if status.find == nil { status.setFind(PaneFind()) }
            status.updateFind { $0.focusRequest += 1 }
            // Use Selection for Find: the terminal names the text but leaves looking for it to us.
            if !needle.isEmpty {
                status.updateFind { $0.needle = needle }
                view.performBindingAction("search:\(needle)")
            }
            return true
        case .endSearch:
            guard case .surface(let view) = target, let pane = view.token?.base as? PaneID else { return false }
            activity.status(for: pane).setFind(nil)
            return true
        case .searchTotal(let total):
            guard case .surface(let view) = target, let pane = view.token?.base as? PaneID else { return false }
            activity.status(for: pane).updateFind { $0.total = total }
            return true
        case .searchSelected(let selected):
            guard case .surface(let view) = target, let pane = view.token?.base as? PaneID else { return false }
            activity.status(for: pane).updateFind { $0.selected = selected }
            return true
        default: break
        }
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
            // Agents animate a spinner in their title many times a second. Every change redraws
            // the tab row, the Agents entry and the window title, and each redraw blocks the main
            // thread on the window server, which also presents the terminal's frames: a working
            // agent made typing and its own animation stutter. Without the spinner the title
            // rarely changes, and an unchanged title changes nothing.
            let shown = Pane.terminalTitle(title)
            guard located.2.title != shown else { return true }
            located.2.title = shown
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
        case .scrollbar, .cellSize:
            return true // handled above, before the pane lookup
        case .render, .configChange:
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
            activity.clearProgress(located.2.id)
            located.3.shell(for: located.2.id)?.commandFinished(code: code, durationNs: duration)
            located.3.blocks(for: located.2.id)?.setNeedsRefresh()
            return true
        case .secureInput(let request):
            guard let located else { return false }
            let pane = located.2.id
            switch request {
            case .on: secureInput.setRequested(pane, true)
            case .off: secureInput.setRequested(pane, false)
            case .toggle: secureInput.setRequested(pane, !secureInput.isRequested(pane))
            }
            refreshSecureIndicators()
            return true
        case .openURL(let kind, let text):
            // Always true, even when refused: false would make libghostty `open` the text itself,
            // past every refusal of `LinkTarget`.
            let decision = LinkTarget.decide(text, kind: kind, relativeTo: located?.2.workingDirectory)
            // Carried out on the next turn of the run loop, never inside this callback: a ⌘-click
            // reaches here with libghostty holding the terminal's lock, and the confirmation's
            // modal alert (or another app coming forward) takes the keys from the window, whose
            // focus change calls back into libghostty for that same lock on this thread.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.openLink(decision) }
            }
            return true
        case .reloadConfig, .openConfig, .mouseShape, .mouseVisibility, .mouseOverLink, .progressReport, .unhandled,
             .startSearch, .endSearch, .searchTotal, .searchSelected:
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
