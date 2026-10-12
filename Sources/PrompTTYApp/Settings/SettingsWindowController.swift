import AppKit
import Preferences
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance, tabs, keyboard
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .tabs: return "Tabs & Windows"
        case .keyboard: return "Keyboard"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "textformat"
        case .tabs: return "macwindow"
        case .keyboard: return "keyboard"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var pane: SettingsPane = .appearance
}

/// System Settings–style window: sections on the left, grouped forms on the right.
struct SettingsView: View {
    let model: SettingsModel
    let swatches: ThemeSwatches
    let fontFamilies: [String]
    @Bindable var navigation: SettingsNavigation

    private var pane: SettingsPane { navigation.pane }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $navigation.pane) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        } detail: {
            Group {
                switch pane {
                case .appearance: AppearanceSection(model: model, swatches: swatches, fontFamilies: fontFamilies)
                case .tabs: TabsSection(model: model)
                case .keyboard: KeyboardSection(model: model)
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

/// The single Settings window, created on first use and reused.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    let navigation = SettingsNavigation()

    init(preferences: PreferencesController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PrompTTYSettings")
        super.init(window: window)
        window.delegate = self
        let root = SettingsView(
            model: preferences.model,
            swatches: ThemeSwatches(catalog: preferences.themes),
            fontFamilies: MonospacedFonts.families(),
            navigation: navigation
        )
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 760, height: 560))
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ pane: SettingsPane? = nil) {
        if let pane { navigation.pane = pane }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    // ⌘W is Close Pane and ⌥⌘W Close Tab; in Settings both close the window, as users expect.
    @objc func closePane(_ sender: Any?) { window?.performClose(sender) }
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }
}
