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
        let view = surfaceView(for: tab)
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
    func applyInitialTerminalSize(_ size: CGSize) {
        guard !appliedInitialSize, let window else { return }
        appliedInitialSize = true
        let inset = TerminalContainerView.inset
        let chromeW = coordinator.workspace.tabLayout == .sidebar ? ChromeView.sidebarWidth + inset : inset * 2
        let chromeH = coordinator.workspace.tabLayout == .sidebar ? inset * 2 : ChromeView.stripHeight + 6 + inset * 2
        let scale = window.backingScaleFactor
        let content = NSSize(width: size.width / scale + chromeW, height: size.height / scale + chromeH)
        window.setContentSize(content)
        window.center()
    }

    func setTabLayout(_ layout: TabLayout, hidden: Bool) {
        // Task 8 installs the real tab list here. For now, a placeholder spacer keeps the chrome layout honest.
        chrome.install(tabList: hidden ? nil : NSView(), layout: layout)
    }

    // MARK: NSWindowDelegate

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
