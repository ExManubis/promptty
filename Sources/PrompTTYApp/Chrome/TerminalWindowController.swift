import AppKit
import GhosttyBridge
import WorkspaceModel

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    let state: WindowState
    private unowned let coordinator: WorkspaceCoordinator
    private let runtime: GhosttyRuntime
    let chrome = ChromeView()
    private var surfaces: [TabID: TerminalSurfaceView] = [:]
    private var appliedInitialSize = false
    /// Last `setTabLayout(_:hidden:)` argument, so initial sizing knows the chrome's footprint.
    private var tabListHidden = false
    /// The tab shown by the last `reload()`; a change resets any OSC 11 tint to the configured one.
    private var shownTabID: TabID?
    private var tabList: TabCollectionView?

    init(state: WindowState, coordinator: WorkspaceCoordinator, runtime: GhosttyRuntime) {
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
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 300)
        super.init(window: window)
        window.delegate = self
        window.contentView = chrome
        if let frame = state.frame {
            window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
            appliedInitialSize = true
        } else {
            window.center()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Re-syncs the visible surface with the model. Called by the coordinator after every mutation.
    func reload() {
        guard let tab = state.selectedTab else { return }
        tabList?.update(tabs: state.tabs, selected: state.selectedTabID)
        let view = surfaceView(for: tab)
        if shownTabID != tab.id {
            shownTabID = tab.id
            coordinator.applyConfiguredTint(to: self)
        }
        chrome.container.show(view)
        window?.title = tab.displayTitle
    }

    func surfaceView(for tab: Tab) -> TerminalSurfaceView {
        if let existing = surfaces[tab.id] { return existing }
        let view = TerminalSurfaceView(
            runtime: runtime,
            configuration: TerminalSurfaceConfiguration(workingDirectory: tab.workingDirectory)
        )
        view.token = tab.id
        surfaces[tab.id] = view
        return view
    }

    func removeSurface(for id: TabID) {
        guard let view = surfaces.removeValue(forKey: id) else { return }
        chrome.container.remove(view)
        view.teardown()
    }

    func allSurfaces() -> [TerminalSurfaceView] { Array(surfaces.values) }

    /// Sizes a fresh window so the terminal grid matches Ghostty's configured default size.
    /// `size` is in points: libghostty already divides by the content scale.
    func applyInitialTerminalSize(_ size: CGSize) {
        guard !appliedInitialSize, let window else { return }
        appliedInitialSize = true
        let inset = TerminalContainerView.inset
        let chromeW: CGFloat
        let chromeH: CGFloat
        if tabListHidden {
            chromeW = inset * 2
            chromeH = ChromeView.trafficLightsHeight + inset
        } else if coordinator.workspace.tabLayout == .sidebar {
            chromeW = ChromeView.sidebarWidth + inset
            chromeH = inset * 2
        } else {
            chromeW = inset * 2
            chromeH = ChromeView.stripHeight + 6 + inset * 2
        }
        let content = NSSize(width: size.width + chromeW, height: size.height + chromeH)
        window.setContentSize(content)
        window.center()
    }

    func setTabLayout(_ layout: TabLayout, hidden: Bool) {
        tabListHidden = hidden
        guard !hidden else {
            tabList = nil
            chrome.install(tabList: nil, layout: layout)
            return
        }
        let list = TabCollectionView(layout: layout)
        list.delegate = self
        tabList = list
        chrome.install(tabList: list, layout: layout)
        reload()
    }

    /// Gives keyboard focus back to the visible terminal (after an inline tab rename).
    /// Deferred a turn so the field editor finishes resigning before focus moves.
    func focusShownSurface() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = self.shownTabID, let view = self.surfaces[id] else { return }
            self.window?.makeFirstResponder(view)
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
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { onConfirm() }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard allSurfaces().contains(where: { $0.needsConfirmQuit }) else { return true }
        confirmClose(message: "Close this window?", informativeText: "A process is still running in one of its tabs.") { [weak self] in
            self?.window?.close()
        }
        return false
    }

    func windowDidResize(_ notification: Notification) { persistFrame() }
    func windowDidMove(_ notification: Notification) { persistFrame() }

    func windowWillClose(_ notification: Notification) {
        coordinator.windowWillClose(state.id)
    }

    private func persistFrame() {
        guard let f = window?.frame else { return }
        state.frame = WindowFrame(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height)
        coordinator.modelDidChange()
    }
}

extension TerminalWindowController: TabCollectionViewDelegate {
    func tabList(_ list: TabCollectionView, didSelect id: TabID) { coordinator.select(id) }
    func tabList(_ list: TabCollectionView, didRequestClose id: TabID) { coordinator.closeTab(id) }
    func tabList(_ list: TabCollectionView, didRename id: TabID, to title: String) { coordinator.rename(id, to: title) }
    func tabList(_ list: TabCollectionView, didMove id: TabID, to index: Int) { coordinator.move(id, to: index) }
    func tabListDidRequestNewTab(_ list: TabCollectionView) { coordinator.newTab(in: state) }
    func tabListDidEndRenaming(_ list: TabCollectionView) { focusShownSurface() }
}
