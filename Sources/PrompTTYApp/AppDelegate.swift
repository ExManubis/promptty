import AppKit
import UserNotifications
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
    private var preferences: PreferencesController!
    private var layoutObserver: NSObjectProtocol?
    private var notificationRouter: NotificationRouter?

    /// With no nib, `@main` alone never instantiates the delegate; install it explicitly and keep
    /// it alive for the lifetime of the run loop (`NSApplication.delegate` is weak).
    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        withExtendedLifetime(delegate) {
            NSApplication.shared.run()
        }
    }

    /// Forgets which commands ran in which folder (the bar's per-folder suggestions).
    @objc func clearFolderHistory(_ sender: Any?) {
        FolderHistoryStore.shared.clear()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SessionStore(url: AppPaths.session)
        sessionStore = store
        let snapshot = store.load()
        do {
            let prefs = PreferencesController(
                supportDirectory: AppPaths.support,
                themesDirectory: try GhosttyLibrary.themesDirectory(),
                legacyTabLayout: snapshot?.tabLayout
            )
            preferences = prefs
            FontRegistration.ensureSFMono()
            try prefs.writeTerminalConfig()
            runtime = try GhosttyRuntime(configURL: prefs.terminalConfigURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = "PrompTTY could not start the terminal engine"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        NSApp.mainMenu = MainMenu.build(shortcuts: preferences.shortcuts)
        if let snapshot, preferences.settings.restoreSession {
            workspace = Workspace.restore(from: snapshot)
        } else {
            workspace = Workspace()
        }
        workspace.tabLayout = TabLayout(preferences.settings.tabLayout)
        ShellIntegration.install()
        EditorStyle.update(family: preferences.settings.fontFamily, size: preferences.settings.fontSize)
        EditorStyle.update(foreground: runtime.configuredForeground, palette: runtime.configuredANSIPalette)
        EditorStyle.cursor = preferences.cursorColor
        coordinator = WorkspaceCoordinator(runtime: runtime, workspace: workspace, preferences: preferences)
        let router = NotificationRouter { [weak self] pane in self?.coordinator.reveal(pane) }
        notificationRouter = router
        UNUserNotificationCenter.current().delegate = router
        preferences.onTerminalConfigChanged = { [weak self] in self?.runtime.reloadConfig() }
        preferences.onShortcutsChanged = { NSApp.mainMenu = MainMenu.build(shortcuts: $0) }
        // Shifted punctuation shortcuts are declared per keyboard layout; rebuild when it changes.
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSApp.mainMenu = MainMenu.build(shortcuts: self.preferences.shortcuts)
            }
        }
        preferences.onAppSettingsChanged = { [weak self] in self?.coordinator.applyAppSettings($0) }
        saver = DebouncedSaver(delay: .seconds(1)) { [weak self] in self?.saveSession() }
        coordinator.onModelChanged = { [weak self] in self?.saver.schedule() }
        runtime.sink = coordinator
        runtime.onConfigDiagnostics = { [weak self] diags in
            self?.coordinator.configDidReload()
            self?.coordinator.showConfigDiagnostics(diags)
        }
        runtime.onSurfaceCreationFailed = { [weak self] view in
            guard let id = view.token?.base as? PaneID else { return }
            // Fires synchronously while SwiftUI places the view (surface creation happens when the
            // view joins the window); defer so closing the pane does not re-enter that update.
            Task { @MainActor [weak self] in
                self?.coordinator.closePane(id)
                self?.coordinator.showTransientBanner("Could not start a terminal for that pane.")
            }
        }
        syncColorScheme()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncColorScheme() }
        }
        coordinator.start()
        #if DEBUG
        DebugDriver.shared.stateProvider = { [weak self] in self?.coordinator.debugState() ?? "" }
        DebugHooks.install(on: DebugDriver.shared, coordinator: coordinator)
        DebugDriver.shared.hooks["settings-open"] = { [weak self] args in
            self?.showSettings(nil)
            if let name = args.first, let pane = SettingsPane(rawValue: name) { self?.settingsWindow?.show(pane) }
            return ""
        }
        DebugDriver.shared.install()
        #endif
        coordinator.showConfigDiagnostics(runtime.configDiagnostics)
        if preferences.recoveredFromBadFile {
            coordinator.showTransientBanner("Settings could not be read and were reset. The old file was kept as settings.json.bak.")
        }
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
        preferences?.flush()
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
    private var settingsWindow: SettingsWindowController?

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let controller = SettingsWindowController(preferences: preferences)
            // Closing Settings hands the keyboard back to the terminal underneath.
            controller.onClose = { [weak self] in
                self?.coordinator.allControllers.first { $0.window?.isMainWindow == true }?.focusSelectedPane()
            }
            settingsWindow = controller
        }
        settingsWindow?.show()
    }

    @objc func biggerFont(_ sender: Any?) { preferences.update { $0.fontSize += 1 } }
    @objc func smallerFont(_ sender: Any?) { preferences.update { $0.fontSize -= 1 } }
    /// Back to the default size; Bigger/Smaller change the setting itself so the size persists.
    @objc func actualSizeFont(_ sender: Any?) { preferences.update { $0.fontSize = Settings().fontSize } }

    private func syncColorScheme() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        runtime.setColorScheme(dark: dark)
        coordinator?.systemAppearanceDidChange(dark: dark)
    }
}
