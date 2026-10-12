import AppKit
import GhosttyBridge
import WorkspaceModel

/// Owns the mapping between the model, window controllers, and surfaces, and is libghostty's action sink.
@MainActor
final class WorkspaceCoordinator: GhosttyActionSink {
    let runtime: GhosttyRuntime
    let workspace: Workspace
    private var controllers: [WindowID: TerminalWindowController] = [:]
    /// Set by Task 10 to schedule a session save.
    var onModelChanged: (() -> Void)?

    init(runtime: GhosttyRuntime, workspace: Workspace) {
        self.runtime = runtime
        self.workspace = workspace
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
    }

    func controller(for id: WindowID) -> TerminalWindowController? { controllers[id] }

    func modelDidChange() { onModelChanged?() }

    /// Tints a window's chrome from the configured terminal background.
    func applyConfiguredTint(to controller: TerminalWindowController) {
        guard let bg = runtime.configuredBackground else {
            controller.chrome.tint = ChromeTint.fallback
            return
        }
        let color = NSColor(srgbRed: CGFloat(bg.red) / 255, green: CGFloat(bg.green) / 255, blue: CGFloat(bg.blue) / 255, alpha: 1)
        controller.chrome.tint = ChromeTint.tint(forTerminalBackground: color)
    }

    /// Called after every config reload.
    func configDidReload() {
        for c in controllers.values { applyConfiguredTint(to: c) }
    }

    // MARK: Banner

    private var configBannerMessage: String?
    /// Bumped per transient banner so an older one's timer does not cut a newer one short.
    private var transientBannerGeneration = 0
    private var transientBannerActive = false

    func showConfigDiagnostics(_ diagnostics: [String]) {
        configBannerMessage = diagnostics.isEmpty ? nil : "Ghostty config: \(diagnostics[0])" + (diagnostics.count > 1 ? " (+\(diagnostics.count - 1) more)" : "")
        guard !transientBannerActive else { return }
        for c in controllers.values { applyBanner(to: c) }
    }

    private func applyBanner(to controller: TerminalWindowController) {
        guard let message = configBannerMessage else {
            controller.chrome.setBanner(nil)
            return
        }
        controller.chrome.setBanner(BannerView(message: message, actionTitle: "Open config") { [weak self] in
            self?.runtime.openConfig()
        })
    }

    /// Shows `message` in every window for a few seconds, then restores the config banner (if any).
    func showTransientBanner(_ message: String) {
        transientBannerGeneration += 1
        transientBannerActive = true
        let generation = transientBannerGeneration
        for c in controllers.values {
            c.chrome.setBanner(BannerView(message: message, actionTitle: nil, action: nil))
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.transientBannerGeneration == generation else { return }
            self.transientBannerActive = false
            for c in self.controllers.values { self.applyBanner(to: c) }
        }
    }

    // MARK: Mutations

    func newWindow(workingDirectory: String? = nil) {
        let state = workspace.addWindow()
        state.addTab(title: "", workingDirectory: workingDirectory ?? NSHomeDirectory())
        open(state)
        controllers[state.id]?.window?.makeKeyAndOrderFront(nil)
        modelDidChange()
    }

    func newTab(in state: WindowState, workingDirectory: String? = nil) {
        let dir = workingDirectory ?? state.selectedTab?.workingDirectory ?? NSHomeDirectory()
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

    /// Closes a tab; closing the last tab closes the window.
    func closeTab(_ id: TabID) {
        guard let state = workspace.window(containing: id), let controller = controllers[state.id] else { return }
        controller.removeSurface(for: id)
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

    func toggleTabLayout() {
        workspace.toggleTabLayout()
        for c in controllers.values { c.setTabLayout(workspace.tabLayout, hidden: tabListHidden) }
        modelDidChange()
    }

    /// ⌘B. A preference, not session state, so it lives in UserDefaults.
    private static let tabListHiddenKey = "tabListHidden"
    var tabListHidden: Bool { UserDefaults.standard.bool(forKey: Self.tabListHiddenKey) }

    func toggleTabListHidden() {
        UserDefaults.standard.set(!tabListHidden, forKey: Self.tabListHiddenKey)
        for c in controllers.values { c.setTabLayout(workspace.tabLayout, hidden: tabListHidden) }
    }

    func windowWillClose(_ id: WindowID) {
        guard let controller = controllers.removeValue(forKey: id) else { return }
        for view in controller.allSurfaces() { view.teardown() }
        workspace.removeWindow(id: id)
        modelDidChange()
    }

    private func open(_ state: WindowState) {
        let controller = TerminalWindowController(state: state, coordinator: self, runtime: runtime)
        controllers[state.id] = controller
        controller.setTabLayout(workspace.tabLayout, hidden: tabListHidden)
        applyBanner(to: controller)
        applyConfiguredTint(to: controller)
        controller.reload()
        controller.showWindow(nil)
    }

    // MARK: Lookup

    private func locate(_ view: TerminalSurfaceView) -> (WindowState, Tab, TerminalWindowController)? {
        guard let id = view.token?.base as? TabID,
              let state = workspace.window(containing: id),
              let tab = state.tab(id: id),
              let controller = controllers[state.id] else { return nil }
        return (state, tab, controller)
    }

    private var keyWindowState: WindowState? {
        controllers.values.first { $0.window?.isKeyWindow == true }?.state ?? workspace.windows.first
    }

    // MARK: GhosttyActionSink

    func handle(_ action: GhosttyAction, target: GhosttyActionTarget) -> Bool {
        let located: (WindowState, Tab, TerminalWindowController)?
        if case .surface(let view) = target { located = locate(view) } else { located = nil }
        let state = located?.0 ?? keyWindowState

        switch action {
        case .newWindow:
            newWindow(workingDirectory: located?.1.workingDirectory)
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
            located.1.title = title
            located.2.reload()
            return true
        case .pwd(let dir):
            guard let located else { return false }
            located.1.workingDirectory = dir
            located.2.reload()
            modelDidChange()
            return true
        case .initialSize(let w, let h):
            guard let located else { return false }
            located.2.applyInitialTerminalSize(CGSize(width: Double(w), height: Double(h)))
            return true
        case .cellSize, .render, .configChange:
            return true
        case .colorChange(let kind, let r, let g, let b):
            // Only the selected tab's background (OSC 11) tints its own window.
            guard kind == .background, let located, located.0.selectedTabID == located.1.id else { return false }
            let color = NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            located.2.chrome.tint = ChromeTint.tint(forTerminalBackground: color)
            return true
        case .showChildExited(let code, _):
            guard let located, case .surface(let view) = target else { return false }
            let tabID = located.1.id
            located.2.chrome.container.showExitedOverlay(for: view, exitCode: code) { [weak self] in
                self?.closeTab(tabID)
            }
            return true
        case .closeSurface(let processAlive):
            guard let located else { return false }
            let tabID = located.1.id
            if processAlive {
                located.2.confirmClose(message: "Close this tab?", informativeText: "A process is still running in it.") { [weak self] in
                    self?.closeTab(tabID)
                }
            } else {
                closeTab(tabID)
            }
            return true
        case .desktopNotification(let title, let body):
            Notifications.post(title: title.isEmpty ? "PrompTTY" : title, body: body)
            return true
        case .ringBell:
            NSSound.beep()
            return true
        case .reloadConfig, .openConfig, .mouseShape, .mouseVisibility, .unhandled:
            // Config, mouse-shape and mouse-visibility actions are handled by the runtime.
            return false
        }
    }
}
