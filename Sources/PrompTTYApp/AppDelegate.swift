import AppKit
import GhosttyBridge
import Preferences
import WorkspaceModel

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime!
    private var workspace: Workspace!
    private var coordinator: WorkspaceCoordinator!
    private var appearanceObservation: NSKeyValueObservation?
    private var sessionStore: SessionStore!
    private var saver: DebouncedSaver!

    /// With no nib, `@main` alone never instantiates the delegate; install it explicitly and keep
    /// it alive for the lifetime of the run loop (`NSApplication.delegate` is weak).
    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        withExtendedLifetime(delegate) {
            NSApplication.shared.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        do {
            // Interim until settings are wired: default settings only.
            let conf = AppPaths.support.appendingPathComponent("terminal.conf")
            try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            try TerminalConfigWriter.render(Settings(), knownThemes: nil).write(to: conf, atomically: true, encoding: .utf8)
            runtime = try GhosttyRuntime(configURL: conf)
        } catch {
            let alert = NSAlert()
            alert.messageText = "PrompTTY could not start the terminal engine"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let store = SessionStore(url: AppPaths.session)
        sessionStore = store
        if let snapshot = store.load() {
            workspace = Workspace.restore(from: snapshot)
        } else {
            workspace = Workspace()
        }
        coordinator = WorkspaceCoordinator(runtime: runtime, workspace: workspace)
        saver = DebouncedSaver(delay: .seconds(1)) { [weak self] in self?.saveSession() }
        coordinator.onModelChanged = { [weak self] in self?.saver.schedule() }
        runtime.sink = coordinator
        runtime.onConfigDiagnostics = { [weak self] diags in
            self?.coordinator.configDidReload()
            self?.coordinator.showConfigDiagnostics(diags)
        }
        runtime.onSurfaceCreationFailed = { [weak self] view in
            guard let id = view.token?.base as? TabID else { return }
            // Fires synchronously inside the controller's `reload()` (surface creation happens when
            // the view joins the window); defer so closing the tab does not re-enter that reload.
            Task { @MainActor [weak self] in
                self?.coordinator.closeTab(id)
                self?.coordinator.showTransientBanner("Could not start a terminal for that tab.")
            }
        }
        syncColorScheme()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncColorScheme() }
        }
        coordinator.start()
        #if DEBUG
        DebugDriver.shared.stateProvider = { [weak self] in self?.coordinator.debugState() ?? "" }
        DebugDriver.shared.install()
        #endif
        coordinator.showConfigDiagnostics(runtime.configDiagnostics)
        NSApp.activate()
    }

    /// Dock-icon click with no windows open (the app outlives its last window). A minimized
    /// window also counts as not visible; returning true lets AppKit restore it instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, !sender.windows.contains(where: \.isMiniaturized) {
            coordinator?.newWindow()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) { runtime?.setFocus(true) }
    func applicationDidResignActive(_ notification: Notification) { runtime?.setFocus(false) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard runtime?.needsConfirmQuit == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit PrompTTY?"
        alert.informativeText = "A process is still running in one of your tabs."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard sessionStore != nil else { return }
        saver?.flush()
        saveSession()
    }

    private func saveSession() {
        do {
            try sessionStore.save(workspace.snapshot())
        } catch {
            NSLog("PrompTTY: could not save session: \(error)")
        }
    }

    // MARK: Menu actions (responder chain)

    @objc func newWindow(_ sender: Any?) { coordinator.newWindow() }
    @objc func toggleTabLayout(_ sender: Any?) { coordinator.toggleTabLayout() }
    @objc func toggleTabListHidden(_ sender: Any?) { coordinator.toggleTabListHidden() }
    @objc func reloadConfig(_ sender: Any?) { runtime.reloadConfig() }

    private func syncColorScheme() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        runtime.setColorScheme(dark: dark)
    }
}
