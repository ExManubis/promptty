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
    private unowned let coordinator: WorkspaceCoordinator
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
        let window = NSWindow(
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
        let view = TerminalSurfaceView(
            runtime: runtime,
            configuration: TerminalSurfaceConfiguration(
                workingDirectory: pane.workingDirectory,
                inheritFrom: pendingInherit.removeValue(forKey: pane.id),
                environment: environment
            )
        )
        view.token = pane.id
        surfaces[pane.id] = view
        let shell = PaneShell(pane: pane.id, directory: pane.workingDirectory, integrated: !environment.isEmpty)
        shell.surface = view
        shells[pane.id] = shell
        bind(view, to: pane.id)
        return view
    }

    func shell(for pane: PaneID) -> PaneShell? { shells[pane] }
    func activity(for pane: PaneID) -> PaneActivity { coordinator.activity.activity(for: pane) }
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
        shell.onPhaseChange = { [weak self] _ in self?.shellPhaseChanged(pane) }
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
            view.removeFromSuperview()
            view.teardown()
            return
        }
        chrome.closingPanes[pane] = ClosingPane(id: pane, tab: tab, surface: view)
        DispatchQueue.main.asyncAfter(deadline: .now() + PaneAnimation.closeDuration + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.chrome.closingPanes[pane] = nil
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
        } else {
            chromeW = inset * 2
            chromeH = ChromeMetrics.titlebarHeight + inset
        }
        window.setContentSize(NSSize(width: size.width + chromeW, height: size.height + chromeH))
        window.center()
    }

    // MARK: ChromeActions

    func selectTab(_ id: TabID) { coordinator.select(id) }

    func requestCloseTab(_ id: TabID) {
        guard let tab = state.tab(id: id) else { return }
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
    func moveTab(_ id: TabID, to index: Int) { coordinator.move(id, to: index) }
    func toggleSidebar() { coordinator.toggleTabListHidden() }
    func split(_ pane: PaneID, direction: SplitDirection) { coordinator.split(pane, direction: direction) }

    /// Asks libghostty to close the pane's surface; it answers through `close_surface_cb`, whose
    /// handler confirms first when a process is still running.
    func requestClosePane(_ pane: PaneID) {
        if let view = surfaces[pane], !view.isTornDown, chrome.exitedPanes[pane] == nil {
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

    @objc func closeTab(_ sender: Any?) {
        guard let id = state.selectedTabID else { return }
        requestCloseTab(id)
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

    private func moveFocus(_ direction: SplitDirection) {
        guard let tab = state.selectedTab, tab.moveFocus(direction) else { return }
        reload()
    }

    @objc func equalizePanes(_ sender: Any?) { state.selectedTab?.equalize() }

    @objc func clearTerminal(_ sender: Any?) { focusedSurface?.performBindingAction("clear_screen") }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(focusPaneLeft(_:)), #selector(focusPaneUp(_:)), #selector(focusPaneRight(_:)),
             #selector(focusPaneDown(_:)), #selector(equalizePanes(_:)):
            return state.selectedTab?.hasSplits ?? false
        case #selector(gotoTab(_:)):
            return item.tag <= state.tabs.count
        case #selector(previousTab(_:)), #selector(nextTab(_:)):
            return state.tabs.count > 1
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    /// Presents a Close/Cancel confirmation sheet on this window; `onConfirm` runs on Close.
    func confirmClose(message: String, informativeText: String, onConfirm: @escaping () -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { onConfirm() } else { self?.focusSelectedPane() }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard coordinator.preferences.settings.confirmCloseRunning,
              allSurfaces().contains(where: { $0.needsConfirmQuit }) else { return true }
        confirmClose(message: "Close this window?", informativeText: "A process is still running in one of its tabs.") { [weak self] in
            self?.window?.close()
        }
        return false
    }

    func windowDidResize(_ notification: Notification) { persistFrame() }
    func windowDidMove(_ notification: Notification) { persistFrame() }
    func windowDidBecomeKey(_ notification: Notification) { focusSelectedPane() }

    func windowWillClose(_ notification: Notification) {
        coordinator.windowWillClose(state.id)
        // The SwiftUI root holds this controller as its ChromeActions; dropping the hosting view
        // breaks controller → window → hosting view → controller, and stops a closed window's
        // view graph from observing the shared workspace and settings.
        window?.contentView = nil
    }

    private func persistFrame() {
        guard let f = window?.frame else { return }
        state.frame = WindowFrame(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height)
        coordinator.modelDidChange()
    }
}
