import AppKit
import GhosttyBridge
import WorkspaceModel

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime!
    private var workspace: Workspace!
    private var coordinator: WorkspaceCoordinator!
    private var appearanceObservation: NSKeyValueObservation?

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
            runtime = try GhosttyRuntime()
        } catch {
            let alert = NSAlert()
            alert.messageText = "PrompTTY could not start the terminal engine"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        workspace = Workspace()
        coordinator = WorkspaceCoordinator(runtime: runtime, workspace: workspace)
        runtime.sink = coordinator
        syncColorScheme()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncColorScheme() }
        }
        coordinator.start()
        NSApp.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) { runtime?.setFocus(true) }
    func applicationDidResignActive(_ notification: Notification) { runtime?.setFocus(false) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func syncColorScheme() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        runtime.setColorScheme(dark: dark)
    }
}
