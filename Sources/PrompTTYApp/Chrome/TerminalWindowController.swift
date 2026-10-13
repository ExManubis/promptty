import AppKit
import CommandEditing
import GhosttyBridge
import PaneActivity
import Preferences
import SwiftUI
import WorkspaceModel

/// One terminal window. AppKit owns the window, focus and menu commands; the contents are the
/// SwiftUI `WindowRootView`. Every pane's `TerminalSurfaceView` is created once and cached here,
/// so SwiftUI only ever places surfaces and never restarts a shell.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate, ChromeActions {
    let state: WindowState
    let chrome = WindowChromeModel()
    unowned let coordinator: WorkspaceCoordinator
    private let runtime: GhosttyRuntime
    private var surfaces: [PaneID: TerminalSurfaceView] = [:]
    /// Each pane's shell session (prompt state, header, history), created with its surface.
    private var shells: [PaneID: PaneShell] = [:]
    /// Source surfaces for panes created by a split, consumed when their surface is made.
    private var pendingInherit: [PaneID: TerminalSurfaceView] = [:]
    private var appliedInitialSize = false
    /// The tab shown by the last `reload()`; a change resets any OSC 11 tint to the configured one.
    private var shownTabID: TabID?

    #if DEBUG
    /// Live controllers, for leak checks in the debug driver.
    nonisolated(unsafe) static var liveCount = 0
    #endif

    init(state: WindowState, coordinator: WorkspaceCoordinator, runtime: GhosttyRuntime) {
        #if DEBUG
        Self.liveCount += 1
        #endif
        self.state = state
        self.coordinator = coordinator
        self.runtime = runtime
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // An empty unified toolbar gives the taller titlebar, so the traffic lights sit centered in
        // the chrome's top band instead of hugging the window edge.
        let toolbar = NSToolbar(identifier: "PrompTTYWindow")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        // See-through so the backdrop can blur the desktop behind the window.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 520, height: 320)
        super.init(window: window)
        window.delegate = self
        window.activityObserver = { [weak self] in self?.noteRefreshActivity() }
        window.keyInterceptor = { [weak self] event in
            guard let self else { return false }
            return self.handleVimNavigation(event) || self.handleBlockKeys(event)
        }
        window.mouseDownObserver = { [weak self] event in self?.mouseDownInWindow(event) }
        let root = WindowRootView(
            state: state,
            workspace: coordinator.workspace,
            settings: coordinator.preferences.model,
            chrome: chrome,
            actions: self
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        window.contentView = hosting
        if let frame = state.frame {
            window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
            appliedInitialSize = true
        } else {
            window.center()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    #if DEBUG
    deinit { Self.liveCount -= 1 }
    #endif

    // MARK: Model sync

    /// Re-syncs window-level state with the model. Called by the coordinator after every mutation;
    /// SwiftUI follows the observable model on its own.
    func reload() {
        guard let tab = state.selectedTab else { return }
        if shownTabID != tab.id {
            shownTabID = tab.id
            coordinator.applyConfiguredTint(to: self)
        }
        window?.title = tab.listTitle
        focusSelectedPane()
    }

    /// Sets the frame (nil for the neutral system color) and the content panel's fill. A tinted
    /// frame sets the window's appearance from its lightness so chrome text stays legible; the
    /// neutral frame follows the system appearance.
    func setColors(frame: NSColor?, panel: NSColor) {
        chrome.panelColor = panel
        if let frame {
            chrome.tint = ChromeTint.overBlur(frame)
            window?.appearance = NSAppearance(named: ChromeTint.isDark(frame) ? .darkAqua : .aqua)
        } else {
            chrome.tint = ChromeTint.fallback
            window?.appearance = nil
        }
    }

    // MARK: Surfaces

    /// The pane's surface, created on first use. Nil for a pane that is no longer in this window:
    /// SwiftUI can evaluate a removed pane's card once more, and a surface made then would start a
    /// shell nothing ever frees.
    func surfaceView(for pane: Pane) -> TerminalSurfaceView? {
        if let existing = surfaces[pane.id] { return existing }
        guard state.tab(containing: pane.id) != nil else { return nil }
        let environment = ShellIntegration.environment(for: pane.id)
        let integrated = !environment.isEmpty
        // A pinned tab's command: run from the bar at the first prompt, or typed ahead into a
        // shell without the integration.
        let startup = pane.startupCommand
        pane.startupCommand = nil
        let view = TerminalSurfaceView(
            runtime: runtime,
            configuration: TerminalSurfaceConfiguration(
                workingDirectory: pane.workingDirectory,
                inheritFrom: pendingInherit.removeValue(forKey: pane.id),
                environment: environment,
                initialInput: integrated ? nil : startup.map { $0 + "\n" }
            )
        )
        view.token = pane.id
        _ = BlockOverlayView(surface: view)
        surfaces[pane.id] = view
        let shell = PaneShell(pane: pane.id, directory: pane.workingDirectory, integrated: integrated,
                              startupCommand: integrated ? startup : nil)
        shell.surface = view
        shells[pane.id] = shell
        bind(view, to: pane.id)
        return view
    }

    func shell(for pane: PaneID) -> PaneShell? { shells[pane] }
    func blocks(for pane: PaneID) -> BlockOverlayView? { surfaces[pane]?.overlay as? BlockOverlayView }
    func activity(for pane: PaneID) -> PaneActivity.Visible { coordinator.activity.activity(for: pane) }
    var agentList: AgentList { coordinator.agentList }
    func reveal(_ pane: PaneID) { coordinator.reveal(pane) }
    func screenText(for pane: PaneID) -> String? { surfaces[pane]?.visibleText() }

    private let previewPanel = PreviewPanel()
    private var previewedTab: TabID?

    func showPreview(of tab: TabID, beside row: CGRect, titled: Bool) {
        guard let window, let model = state.tab(id: tab) else { return }
        previewedTab = tab
        previewPanel.show(
            TabPreview(tab: model, actions: self, chrome: chrome, titled: titled),
            beside: row, in: window
        )
    }

    func hidePreview(of tab: TabID) {
        guard previewedTab == tab else { return }
        previewedTab = nil
        previewPanel.hide()
    }
    func allShells() -> [PaneShell] { Array(shells.values) }

    private func bind(_ view: TerminalSurfaceView, to pane: PaneID) {
        view.onFocus = { [weak self] in self?.coordinator.paneDidFocus(pane) }
        view.onAttachedToWindow = { [weak self] in self?.surfaceAttached(pane) }
        // Dropped files: into the bar while it is shown, else typed for the program, quoted.
        view.onFileDrop = { [weak self, weak view] urls in
            if let shell = self?.shells[pane], shell.bar != .hidden {
                shell.editor.textView.insertDroppedFiles(urls)
            } else {
                view?.sendText(urls.map { ShellQuoting.escape($0.path) }.joined(separator: " ") + " ")
            }
            return true
        }
        guard let shell = shells[pane] else { return }
        // At a prompt the bar takes the keys, even after a click into the terminal's output
        // (which still selects text there).
        view.keyRedirect = { [weak shell] in
            guard let shell, shell.bar != .hidden else { return nil }
            return shell.editor.textView
        }
        shell.editor.textView.onFocus = { [weak self] in self?.coordinator.paneDidFocus(pane) }
        shell.onPhaseChange = { [weak self] phase in
            if phase == .running { self?.blocks(for: pane)?.commandStarted() } else { self?.blocks(for: pane)?.setNeedsRefresh() }
            self?.shellPhaseChanged(pane)
        }
    }

    /// Where a pane's keys go: the input bar while it is shown (at a prompt, and in the moment a
    /// quick command runs, so typing ahead of it lands in the bar), the terminal otherwise.
    private func focusTarget(for pane: PaneID) -> NSView? {
        if let shell = shells[pane], shell.bar != .hidden { return shell.editor.textView }
        return surfaces[pane]
    }

    /// A pane reached a prompt or started a command: if it has focus, its keys move.
    private func shellPhaseChanged(_ pane: PaneID) {
        guard let tab = state.selectedTab, tab.focusedPaneID == pane else { return }
        focusSelectedPane()
    }

    /// A surface (re)joined the window, e.g. after SwiftUI re-hosted it during a rearrangement.
    /// If it is the pane that should have focus and nothing else holds it, give it back.
    private func surfaceAttached(_ pane: PaneID) {
        guard let window, let tab = state.selectedTab, tab.focusedPaneID == pane,
              chrome.renamingTab == nil, let view = focusTarget(for: pane), view.window === window else { return }
        let current = window.firstResponder
        if current === view || (current is NSText && current !== surfaces[pane]) { return }
        window.makeFirstResponder(view)
    }

    func existingSurface(for pane: PaneID) -> TerminalSurfaceView? { surfaces[pane] }

    /// Records that `pane`'s surface should inherit from `source` when it is created.
    func prepareSplit(_ pane: PaneID, inheritingFrom source: PaneID) {
        if let s = surfaces[source] { pendingInherit[pane] = s }
    }

    /// Hands a live surface and its shell session to another window (pane moved across windows).
    func relinquishSurface(for pane: PaneID) -> (TerminalSurfaceView, PaneShell?)? {
        guard let view = surfaces.removeValue(forKey: pane) else { return nil }
        return (view, shells.removeValue(forKey: pane))
    }

    func adoptSurface(_ view: TerminalSurfaceView, shell: PaneShell?, for pane: PaneID) {
        surfaces[pane] = view
        shells[pane] = shell
        bind(view, to: pane)
    }

    /// Frees a pane's surface. When the pane is closing out of `tab` (which stays open) and that
    /// tab is on screen, the surface lives on for a moment so its card can shrink away.
    func removeSurface(for pane: PaneID, closingOutOf tab: TabID? = nil) {
        pendingInherit[pane] = nil
        chrome.exitedPanes[pane] = nil
        shells.removeValue(forKey: pane)?.stop()
        guard let view = surfaces.removeValue(forKey: pane) else { return }
        guard let tab, tab == state.selectedTabID, window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.overlay?.removeFromSuperview()
            view.removeFromSuperview()
            view.teardown()
            return
        }
        chrome.closingPanes[pane] = ClosingPane(id: pane, tab: tab, surface: view)
        DispatchQueue.main.asyncAfter(deadline: .now() + PaneAnimation.closeDuration + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.chrome.closingPanes[pane] = nil
                view.overlay?.removeFromSuperview()
                view.removeFromSuperview()
                view.teardown()
            }
        }
    }

    func allSurfaces() -> [TerminalSurfaceView] { Array(surfaces.values) }

    /// The window is closing: stop every shell session's timers and forget their state files.
    func stopShells() {
        for shell in shells.values { shell.stop() }
        shells.removeAll()
    }

    // MARK: Focus

    private var focusGeneration = 0

    /// Makes the selected tab's focused pane first responder once SwiftUI has placed it.
    func focusSelectedPane() {
        focusGeneration += 1
        let generation = focusGeneration
        attemptFocus(generation: generation, attemptsLeft: 60)
    }

    /// SwiftUI installs a surface in its host on a later layout pass (and after a move, possibly
    /// several), so poll briefly until the surface is in this window.
    private func attemptFocus(generation: Int, attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attemptsLeft == 60 ? 0 : 0.016)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.focusGeneration, let window = self.window,
                      let tab = self.state.selectedTab, self.chrome.renamingTab == nil,
                      let view = self.focusTarget(for: tab.focusedPaneID) else { return }
                if view.window === window {
                    if window.firstResponder !== view { window.makeFirstResponder(view) }
                } else if attemptsLeft > 0 {
                    self.attemptFocus(generation: generation, attemptsLeft: attemptsLeft - 1)
                }
            }
        }
    }

    var focusedSurface: TerminalSurfaceView? {
        state.selectedTab.flatMap { surfaces[$0.focusedPaneID] }
    }

    // MARK: Sizing

    /// Sizes a fresh window so the terminal grid matches libghostty's default size.
    /// `size` is in points: libghostty already divides by the content scale.
    func applyInitialTerminalSize(_ size: CGSize) {
        guard !appliedInitialSize, let window else { return }
        appliedInitialSize = true
        let settings = coordinator.preferences.settings
        let inset = ChromeMetrics.inset
        let chromeW: CGFloat
        let chromeH: CGFloat
        if !settings.tabListHidden, coordinator.workspace.tabLayout == .sidebar {
            chromeW = settings.sidebarWidth + inset
            chromeH = inset * 2
        } else if coordinator.workspace.tabLayout == .sidebar {
            chromeW = inset * 2
            chromeH = inset * 2
        } else {
            chromeW = inset * 2
            chromeH = ChromeMetrics.titlebarHeight + inset
        }
        window.setContentSize(NSSize(width: size.width + chromeW, height: size.height + chromeH))
        window.center()
    }

    /// Bumped on each change, so a delayed fade-in that a newer change overtook does nothing.
    private var trafficLightsGeneration = 0

    func setTrafficLightsShown(_ shown: Bool) {
        guard let window else { return }
        trafficLightsGeneration += 1
        let generation = trafficLightsGeneration
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        func fade() {
            if shown { buttons.forEach { $0.isHidden = false } }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.18
                buttons.forEach { $0.animator().alphaValue = shown ? 1 : 0 }
            } completionHandler: {
                // Hidden, not only transparent: an invisible close button must not take clicks.
                MainActor.assumeIsolated {
                    if !shown, generation == self.trafficLightsGeneration { buttons.forEach { $0.isHidden = true } }
                }
            }
        }
        // The buttons cannot slide with the sidebar: they leave at once and come back once it has
        // mostly slid in, not over it.
        guard shown, !reduceMotion else { return fade() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            MainActor.assumeIsolated {
                guard generation == self.trafficLightsGeneration else { return }
                fade()
            }
        }
    }

    // MARK: ChromeActions

    func selectTab(_ id: TabID) { coordinator.select(id) }

    func requestCloseTab(_ id: TabID) {
        guard let tab = state.tab(id: id) else { return }
        // A pinned tab cannot be closed; it is unpinned first.
        guard tab.pin == nil else {
            NSSound.beep()
            return
        }
        let running = tab.orderedPanes.contains { surfaces[$0.id]?.needsConfirmQuit == true }
        guard running, coordinator.preferences.settings.confirmCloseRunning else {
            coordinator.closeTab(id)
            return
        }
        confirmClose(message: "Close this tab?", informativeText: "A process is still running in it.") { [weak self] in
            self?.coordinator.closeTab(id)
        }
    }

    func newTab() { coordinator.newTab(in: state) }
    func renameTab(_ id: TabID, to title: String) { coordinator.rename(id, to: title) }
    func endRenaming() { focusSelectedPane() }
    func moveTab(_ id: TabID, to index: Int) {
        guard state.tab(id: id) != nil else { return }
        coordinator.move(id, to: index)
    }
    // A tab dragged in from another window is not this window's to pin, unpin or move.
    func pinTab(_ id: TabID, at index: Int?) {
        guard state.tab(id: id) != nil else { return }
        coordinator.pin(id, at: index)
    }
    func setPinnedIcon(_ id: TabID, _ icon: PinIcon?) {
        guard state.tab(id: id) != nil else { return }
        coordinator.setPinnedIcon(id, icon)
    }
    func unpinTab(_ id: TabID, at index: Int?) {
        guard state.tab(id: id) != nil else { return }
        coordinator.unpin(id, at: index)
    }

    /// Ends what runs in the tab, so it asks first, as closing it would.
    func resetPinnedTab(_ id: TabID) {
        guard let tab = state.tab(id: id), tab.pin != nil else { return }
        let running = tab.orderedPanes.contains { surfaces[$0.id]?.needsConfirmQuit == true }
        guard running, coordinator.preferences.settings.confirmCloseRunning else {
            coordinator.resetPinned(id, runningCommand: true)
            return
        }
        confirmClose(message: "Reset this tab?", informativeText: "A process is still running in it.", confirmTitle: "Reset") { [weak self] in
            self?.coordinator.resetPinned(id, runningCommand: true)
        }
    }

    /// A sheet with the command a pinned tab runs on relaunch and reset.
    func editPinnedCommand(_ id: TabID) {
        guard let window, window.attachedSheet == nil, let tab = state.tab(id: id), let pin = tab.pin else { return }
        let alert = NSAlert()
        alert.messageText = "Pinned Command"
        alert.informativeText = "Runs in \(Tab.abbreviate(pin.directory)) when PrompTTY opens and when the tab is reset. Leave it empty for just a shell."
        let field = NSTextField(string: pin.command ?? "")
        field.placeholderString = "npm run dev"
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.coordinator.setPinnedCommand(id, field.stringValue) }
            self?.focusSelectedPane()
        }
    }

    // MARK: Projects

    /// A sheet for the new project's name, suggesting the tab's repository's.
    func newProject(adding tab: TabID?) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "New Project"
        alert.informativeText = tab == nil ? "Group tabs and their agents under a name." : "The tab moves into it; drag more tabs or agents onto it later."
        let field = NSTextField(string: coordinator.suggestedProjectName(for: tab))
        field.placeholderString = Project.untitled
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create Project")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.coordinator.addProject(name: field.stringValue, adding: tab) }
            self?.focusSelectedPane()
        }
    }

    var projects: [Project] { coordinator.workspace.projects }

    func newTab(inProject project: ProjectID?) {
        if let project {
            coordinator.newTab(in: state, project: project)
        } else {
            coordinator.newTab(in: state, inheritingProject: false)
        }
    }

    func placeTab(_ id: TabID, inProject project: ProjectID?) { coordinator.placeTab(id, inProject: project) }

    func requestRenameTab(_ id: TabID) {
        guard let window, window.attachedSheet == nil,
              let tab = coordinator.workspace.window(containing: id)?.tab(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        let field = NSTextField(string: tab.customTitle ?? tab.listTitle)
        field.placeholderString = tab.title.isEmpty ? Tab.fallbackTitle : tab.title
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.coordinator.rename(id, to: field.stringValue) }
            self?.focusSelectedPane()
        }
    }

    func renameProject(_ id: ProjectID) {
        guard let window, window.attachedSheet == nil, let project = coordinator.workspace.project(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Project"
        let field = NSTextField(string: project.name)
        field.placeholderString = project.name
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.coordinator.renameProject(id, to: field.stringValue) }
            self?.focusSelectedPane()
        }
    }

    func setProjectIcon(_ id: ProjectID, _ icon: PinIcon?) { coordinator.setProjectIcon(id, icon) }
    func setProjectFolded(_ id: ProjectID, _ folded: Bool) { coordinator.setProjectFolded(id, folded) }
    func moveProject(_ id: ProjectID, by offset: Int) { coordinator.moveProject(id, by: offset) }
    func moveProject(_ id: ProjectID, to index: Int) { coordinator.moveProject(id, to: index) }

    func requestRemoveProject(_ id: ProjectID) {
        guard let project = coordinator.workspace.project(id: id) else { return }
        let count = coordinator.tabCount(inProject: id)
        let tabs = count == 1 ? "Its tab stays open" : "Its \(count) tabs stay open"
        confirmClose(message: "Remove “\(project.name)”?",
                     informativeText: count == 0 ? "The project has no tabs." : "\(tabs), in no project.",
                     confirmTitle: "Remove") { [weak self] in
            self?.coordinator.removeProject(id)
            self?.focusSelectedPane()
        }
    }

    func toggleSidebar() { coordinator.toggleTabListHidden() }
    func split(_ pane: PaneID, direction: SplitDirection) { coordinator.split(pane, direction: direction) }

    /// Asks libghostty to close the pane's surface; it answers through `close_surface_cb`, whose
    /// handler confirms first when a process is still running.
    func requestClosePane(_ pane: PaneID) {
        let live = surfaces[pane].map { !$0.isTornDown } ?? false && chrome.exitedPanes[pane] == nil
        // Nor can a pinned tab's last pane; once its shell has exited, it is restarted.
        if let tab = state.tab(containing: pane), tab.pin != nil, !tab.hasSplits {
            if live { NSSound.beep() } else { coordinator.resetPinned(tab.id, runningCommand: false) }
            return
        }
        if let view = surfaces[pane], live {
            view.requestClose()
        } else {
            coordinator.closePane(pane)
        }
    }

    func focusPane(_ pane: PaneID) { coordinator.paneDidFocus(pane) }

    func setRatio(in tab: TabID, at path: SplitPath, _ ratio: Double) {
        state.tab(id: tab)?.setRatio(at: path, ratio)
    }

    func movePane(_ pane: PaneID, to target: PaneID, edge: PaneEdge) { coordinator.movePane(pane, to: target, edge: edge) }
    func movePane(_ pane: PaneID, intoTab tab: TabID) { coordinator.movePane(pane, intoTab: tab) }

    // MARK: Menu actions (responder chain)

    @objc func newTab(_ sender: Any?) { newTab() }
    @objc func newProject(_ sender: Any?) { newProject(adding: state.selectedTabID) }

    @objc func closeTab(_ sender: Any?) {
        guard let id = state.selectedTabID else { return }
        requestCloseTab(id)
    }

    @objc func togglePinTab(_ sender: Any?) {
        guard let tab = state.selectedTab else { return }
        if tab.pin == nil { pinTab(tab.id, at: nil) } else { unpinTab(tab.id, at: nil) }
    }

    @objc func closePane(_ sender: Any?) {
        guard let tab = state.selectedTab else { return }
        requestClosePane(tab.focusedPaneID)
    }

    @objc func previousTab(_ sender: Any?) {
        if state.gotoTab(.previous) { reload(); coordinator.modelDidChange() }
    }

    @objc func nextTab(_ sender: Any?) {
        if state.gotoTab(.next) { reload(); coordinator.modelDidChange() }
    }

    /// Go to Tab N; the menu item's tag is N.
    @objc func gotoTab(_ sender: Any?) {
        guard let n = (sender as? NSMenuItem)?.tag else { return }
        if state.gotoTab(.index(n)) { reload(); coordinator.modelDidChange() }
    }

    @objc func splitRight(_ sender: Any?) { splitFocused(.right) }
    @objc func splitDown(_ sender: Any?) { splitFocused(.down) }

    private func splitFocused(_ direction: SplitDirection) {
        guard let tab = state.selectedTab else { return }
        split(tab.focusedPaneID, direction: direction)
    }

    @objc func focusPaneLeft(_ sender: Any?) { moveFocus(.left) }
    @objc func focusPaneUp(_ sender: Any?) { moveFocus(.up) }
    @objc func focusPaneRight(_ sender: Any?) { moveFocus(.right) }
    @objc func focusPaneDown(_ sender: Any?) { moveFocus(.down) }

    /// ⌥H/J/K/L and ⌥⇧J/K, before the terminal or the input bar sees them. Other text fields
    /// (renaming a tab) and text being composed keep their keys.
    func handleVimNavigation(_ event: NSEvent) -> Bool {
        guard coordinator.preferences.settings.vimNavigation, window?.attachedSheet == nil,
              let responder = window?.firstResponder,
              responder is TerminalSurfaceView || responder is CommandTextView,
              (responder as? NSTextInputClient)?.hasMarkedText() != true,
              let key = event.charactersIgnoringModifiers else { return false }
        let flags = event.modifierFlags
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        guard let command = VimNavigation.command(key: key, modifiers: modifiers) else { return false }
        switch command {
        case .focusPane(let direction):
            switch direction {
            case .left: moveFocus(.left)
            case .down: moveFocus(.down)
            case .up: moveFocus(.up)
            case .right: moveFocus(.right)
            }
        case .nextTab: nextTab(nil)
        case .previousTab: previousTab(nil)
        }
        return true
    }

    private func moveFocus(_ direction: SplitDirection) {
        guard let tab = state.selectedTab, tab.moveFocus(direction) else { return }
        reload()
    }

    @objc func equalizePanes(_ sender: Any?) { state.selectedTab?.equalize() }

    @objc func clearTerminal(_ sender: Any?) {
        focusedSurface?.performBindingAction("clear_screen")
        (focusedSurface?.overlay as? BlockOverlayView)?.commandStarted()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(focusPaneLeft(_:)), #selector(focusPaneUp(_:)), #selector(focusPaneRight(_:)),
             #selector(focusPaneDown(_:)), #selector(equalizePanes(_:)):
            return state.selectedTab?.hasSplits ?? false
        case #selector(gotoTab(_:)):
            return item.tag <= state.tabs.count
        case #selector(previousTab(_:)), #selector(nextTab(_:)):
            return state.tabs.count > 1
        case #selector(selectPreviousCommand(_:)), #selector(selectNextCommand(_:)),
             #selector(copyCommandOutput(_:)), #selector(copyCommandLine(_:)):
            return focusedBlocks?.hasBlocks ?? false
        case #selector(togglePinTab(_:)):
            item.title = state.selectedTab?.pin == nil ? "Pin Tab" : "Unpin Tab"
            return state.selectedTab != nil
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    /// Presents a Close/Cancel confirmation sheet on this window; `onConfirm` runs on Close.
    func confirmClose(message: String, informativeText: String, confirmTitle: String = "Close", onConfirm: @escaping () -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informativeText
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { onConfirm() } else { self?.focusSelectedPane() }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Pinned tabs are kept per window: closing it is the one way they are lost.
        if state.pinnedCount > 0 {
            let count = state.pinnedCount
            confirmClose(message: "Close this window?",
                         informativeText: count == 1 ? "Its pinned tab will be closed too." : "Its \(count) pinned tabs will be closed too.") { [weak self] in
                self?.window?.close()
            }
            return false
        }
        guard coordinator.preferences.settings.confirmCloseRunning,
              allSurfaces().contains(where: { $0.needsConfirmQuit }) else { return true }
        confirmClose(message: "Close this window?", informativeText: "A process is still running in one of its tabs.") { [weak self] in
            self?.window?.close()
        }
        return false
    }

    /// In full screen AppKit moves the (empty) toolbar into a window of its own pinned over the
    /// top of the content; hidden until the pointer reaches the top edge, as the menu bar is, it
    /// covers nothing.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union([.autoHideToolbar, .autoHideMenuBar])
    }

    func windowDidResize(_ notification: Notification) { persistFrame() }
    func windowDidMove(_ notification: Notification) { persistFrame() }
    func windowDidBecomeKey(_ notification: Notification) {
        focusSelectedPane()
        noteRefreshActivity()
    }
    func windowDidResignKey(_ notification: Notification) { updateRefreshRate() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateRefreshRate() }

    func windowWillClose(_ notification: Notification) {
        // The display link retains this controller; it must go before the window does.
        refreshLink?.invalidate()
        refreshLink = nil
        coordinator.windowWillClose(state.id)
        // The SwiftUI root holds this controller as its ChromeActions; dropping the hosting view
        // breaks controller → window → hosting view → controller, and stops a closed window's
        // view graph from observing the shared workspace and settings.
        window?.contentView = nil
    }

    // MARK: Refresh rate

    /// Asks for the display's full refresh rate (Settings › Appearance › Display). A ProMotion
    /// display otherwise lowers its rate when little changes, down to 24 Hz, and the frame for
    /// the next keystroke can wait up to a refresh of that length. Runs only while this window
    /// is in front, visible, of the active app, and only while something is changing: it starts
    /// on key input or terminal output and stops after `refreshIdleSeconds` without either.
    private var refreshLink: CADisplayLink?
    /// When a key was last pressed or the terminal last drew.
    private var lastRefreshActivity: CFTimeInterval = 0
    private static let refreshIdleSeconds: CFTimeInterval = 1
    /// Display link callbacks, for the debug driver: the rate the system granted.
    private(set) var refreshTicks = 0
    #if DEBUG
    /// Debug driver: allows the display link without the app in front (a driven app never is);
    /// it still starts and stops with activity.
    var forceFullRefreshRate = false
    #endif

    /// Key input or terminal output: keeps the link running, or starts it. Called at every
    /// runtime wakeup, so it only stamps the time while the link runs.
    func noteRefreshActivity() {
        lastRefreshActivity = CACurrentMediaTime()
        if refreshLink == nil { updateRefreshRate() }
    }

    func updateRefreshRate() {
        var wanted = coordinator.preferences.settings.fullRefreshRate && NSApp.isActive
            && window?.isKeyWindow == true && window?.occlusionState.contains(.visible) == true
        #if DEBUG
        wanted = wanted || forceFullRefreshRate
        #endif
        if wanted, refreshLink == nil, let view = window?.contentView {
            let link = view.displayLink(target: self, selector: #selector(refreshTick(_:)))
            let rate = Float(window?.screen?.maximumFramesPerSecond ?? 120)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common)
            refreshLink = link
            lastRefreshActivity = CACurrentMediaTime() // activation or the setting turning on counts
        } else if !wanted, let link = refreshLink {
            link.invalidate()
            refreshLink = nil
        }
    }

    /// Output that redraws in place (full-screen programs, spinners, progress lines, coding
    /// agents) wakes the runtime no more than a still screen does, so a program running in the
    /// focused pane counts as activity too. Only an idle shell prompt lets the link stop.
    private var focusedPaneIsBusy: Bool {
        guard let id = state.selectedTab?.focusedPaneID, let shell = shells[id] else { return false }
        return shell.phase != .idle
    }

    @objc private func refreshTick(_ link: CADisplayLink) {
        refreshTicks &+= 1
        if focusedPaneIsBusy { lastRefreshActivity = CACurrentMediaTime() }
        if CACurrentMediaTime() - lastRefreshActivity > Self.refreshIdleSeconds {
            link.invalidate()
            refreshLink = nil
        }
    }

    private func persistFrame() {
        guard let f = window?.frame else { return }
        state.frame = WindowFrame(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height)
        coordinator.modelDidChange()
    }
}

/// The terminal window: lets its controller take a key before anything in the window does, as
/// both real key presses and the debug driver's go through `sendEvent`. ⌘ and ⌃ keys are offered
/// as key equivalents first, before the menus, so the controller sees those there.
final class TerminalWindow: NSWindow {
    var keyInterceptor: ((NSEvent) -> Bool)?
    /// Told of every click before it is delivered.
    var mouseDownObserver: ((NSEvent) -> Void)?
    /// Told of every key press, whichever view takes it (terminal or input bar), and of each
    /// wakeup of the terminal runtime (output).
    var activityObserver: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown { activityObserver?() }
        if event.type == .keyDown, keyInterceptor?(event) == true { return }
        if event.type == .leftMouseDown { mouseDownObserver?(event) }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown { activityObserver?() }
        if event.type == .keyDown, keyInterceptor?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
