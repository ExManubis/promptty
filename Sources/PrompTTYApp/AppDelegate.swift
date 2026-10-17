import AppKit
import UserNotifications
import GhosttyBridge
import Preferences
import WorkspaceModel

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var runtime: GhosttyRuntime!
    private var workspace: Workspace!
    private var coordinator: WorkspaceCoordinator!
    private var appearanceObservation: NSKeyValueObservation?
    private var sessionStore: SessionStore!
    private var saver: DebouncedSaver!
    private var scrollbackTimer: Timer?
    private var quickTerminal: QuickTerminal?
    /// What the quick terminal was last set up with, so unrelated settings changes leave it be.
    private var quickTerminalSetup: (on: Bool, shortcut: Shortcut)?
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

    /// Forces secure keyboard entry on while PrompTTY is in front, or lets go of that.
    @objc func toggleSecureKeyboardEntry(_ sender: Any?) {
        preferences.update { $0.secureKeyboardEntry.toggle() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSecureKeyboardEntry(_:)) {
            item.state = preferences?.settings.secureKeyboardEntry == true ? .on : .off
        }
        return true
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
        // Read now, off the main thread, so ⌘J and the bar's suggestions have it when first asked.
        _ = FolderHistoryStore.shared
        EditorStyle.update(family: preferences.settings.fontFamily, size: preferences.settings.fontSize)
        EditorStyle.update(foreground: runtime.configuredForeground, palette: runtime.configuredANSIPalette)
        EditorStyle.cursor = preferences.cursorColor
        coordinator = WorkspaceCoordinator(runtime: runtime, workspace: workspace, preferences: preferences)
        let router = NotificationRouter { [weak self] pane in self?.coordinator.reveal(pane) }
        notificationRouter = router
        UNUserNotificationCenter.current().delegate = router
        preferences.onTerminalConfigChanged = { [weak self] in
            self?.coordinator.denyClipboardRequests()
            self?.runtime.reloadConfig()
        }
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
        let quick = QuickTerminal(runtime: runtime)
        quickTerminal = quick
        coordinator.quickTerminal = quick
        applyQuickTerminal()
        preferences.onAppSettingsChanged = { [weak self] in
            self?.coordinator.applyAppSettings($0)
            self?.applyQuickTerminal()
        }
        saver = DebouncedSaver(delay: .seconds(1)) { [weak self] in self?.saveSession() }
        coordinator.onModelChanged = { [weak self] in self?.saver.schedule() }
        scrollbackTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession(archivingScrollback: true) }
        }
        scrollbackTimer?.tolerance = 30
        runtime.sink = coordinator
        // Output in any terminal wakes the runtime (`.render` is never sent on macOS). The 120 Hz
        // link runs only in the key window, so that is the only one told.
        runtime.onTick = {
            #if DEBUG
            // A driven app has no key window.
            if NSApp.keyWindow == nil { (NSApp.windows.first { $0 is TerminalWindow } as? TerminalWindow)?.activityObserver?(); return }
            #endif
            (NSApp.keyWindow as? TerminalWindow)?.activityObserver?()
        }
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

    func applicationDidBecomeActive(_ notification: Notification) {
        runtime?.setFocus(true)
        coordinator?.appActivationChanged()
    }
    func applicationDidResignActive(_ notification: Notification) {
        runtime?.setFocus(false)
        coordinator?.appActivationChanged()
    }

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
        coordinator?.secureInput.shutDown()
        coordinator?.stopHooks()
        saver?.flush()
        saveSession(archivingScrollback: true)
    }

    /// `archivingScrollback`: also write what each tab shows (at quit, and now and then, so a crash
    /// loses little); otherwise the files written last are named.
    private func saveSession(archivingScrollback: Bool = false) {
        let names = archivingScrollback ? coordinator?.archiveScrollback() ?? [:] : coordinator?.archivedScrollback ?? [:]
        do {
            try sessionStore.save(workspace.snapshot { names[$0.id] })
        } catch {
            NSLog("PrompTTY: could not save session: \(error)")
        }
    }

    /// Registers the quick terminal's global shortcut for the current settings. A driven debug
    /// run registers none: it would take the keys of whoever uses the machine.
    private func applyQuickTerminal() {
        guard let quickTerminal, let preferences else { return }
        let setup = (on: preferences.settings.quickTerminal && !AppPaths.isDriven, shortcut: preferences.shortcuts.shortcut(for: .quickTerminal))
        if let last = quickTerminalSetup, last.on == setup.on, last.shortcut == setup.shortcut { return }
        quickTerminalSetup = setup
        var settings = preferences.settings
        settings.quickTerminal = setup.on
        quickTerminal.apply(settings, shortcut: setup.shortcut)
    }

    @objc func toggleQuickTerminal(_ sender: Any?) { quickTerminal?.toggle() }

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
