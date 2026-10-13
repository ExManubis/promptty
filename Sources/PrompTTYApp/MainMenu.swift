import AppKit
import Preferences

/// The menu bar. Every editable shortcut comes from `ShortcutMap`, and every shortcut contains ⌘,
/// so no menu item ever takes a key the terminal should get. (Vim-style navigation, ⌥H/J/K/L and
/// ⌥⇧J/K, is taken by the terminal window itself; see `VimNavigation`.)
enum MainMenu {
    /// Responder-chain actions, implemented by `AppDelegate` and `TerminalWindowController`.
    enum Action {
        static let newWindow = #selector(AppDelegate.newWindow(_:))
        static let showSettings = #selector(AppDelegate.showSettings(_:))
        static let toggleTabLayout = #selector(AppDelegate.toggleTabLayout(_:))
        static let toggleTabListHidden = #selector(AppDelegate.toggleTabListHidden(_:))
        static let biggerFont = #selector(AppDelegate.biggerFont(_:))
        static let smallerFont = #selector(AppDelegate.smallerFont(_:))
        static let actualSizeFont = #selector(AppDelegate.actualSizeFont(_:))
        static let newTab = #selector(TerminalWindowController.newTab(_:))
        static let newProject = #selector(TerminalWindowController.newProject(_:))
        static let closeTab = #selector(TerminalWindowController.closeTab(_:))
        static let togglePinTab = #selector(TerminalWindowController.togglePinTab(_:))
        static let closePane = #selector(TerminalWindowController.closePane(_:))
        static let previousTab = #selector(TerminalWindowController.previousTab(_:))
        static let nextTab = #selector(TerminalWindowController.nextTab(_:))
        static let gotoTab = #selector(TerminalWindowController.gotoTab(_:))
        static let splitRight = #selector(TerminalWindowController.splitRight(_:))
        static let splitDown = #selector(TerminalWindowController.splitDown(_:))
        static let focusPaneLeft = #selector(TerminalWindowController.focusPaneLeft(_:))
        static let focusPaneUp = #selector(TerminalWindowController.focusPaneUp(_:))
        static let focusPaneRight = #selector(TerminalWindowController.focusPaneRight(_:))
        static let focusPaneDown = #selector(TerminalWindowController.focusPaneDown(_:))
        static let equalizePanes = #selector(TerminalWindowController.equalizePanes(_:))
        static let zoomPane = #selector(TerminalWindowController.zoomPane(_:))
        static let clearTerminal = #selector(TerminalWindowController.clearTerminal(_:))
        static let selectPreviousCommand = #selector(TerminalWindowController.selectPreviousCommand(_:))
        static let selectNextCommand = #selector(TerminalWindowController.selectNextCommand(_:))
        static let copyCommandOutput = #selector(TerminalWindowController.copyCommandOutput(_:))
        static let copyCommandLine = #selector(TerminalWindowController.copyCommandLine(_:))
    }

    static func build(shortcuts: ShortcutMap) -> NSMenu {
        func item(_ title: String, _ action: Selector, _ shortcutAction: ShortcutAction? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            if let shortcutAction { apply(shortcuts.shortcut(for: shortcutAction), to: item) }
            return item
        }
        func fixed(_ title: String, _ action: Selector, _ key: String, _ mask: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            return item
        }

        let menu = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About PrompTTY", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(fixed("Settings…", Action.showSettings, ","))
        app.addItem(withTitle: "Secure Keyboard Entry", action: #selector(AppDelegate.toggleSecureKeyboardEntry(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Clear Folder Suggestions", action: #selector(AppDelegate.clearFolderHistory(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(fixed("Hide PrompTTY", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(fixed("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(fixed("Quit PrompTTY", #selector(NSApplication.terminate(_:)), "q"))
        menu.addItem(submenu: app, title: "PrompTTY")

        let file = NSMenu(title: "File")
        file.addItem(item("New Window", Action.newWindow, .newWindow))
        file.addItem(item("New Tab", Action.newTab, .newTab))
        file.addItem(item("Pin Tab", Action.togglePinTab))
        file.addItem(item("New Project…", Action.newProject))
        file.addItem(.separator())
        file.addItem(item("Split Right", Action.splitRight, .splitRight))
        file.addItem(item("Split Down", Action.splitDown, .splitDown))
        file.addItem(.separator())
        file.addItem(item("Close Pane", Action.closePane, .closePane))
        file.addItem(item("Close Tab", Action.closeTab, .closeTab))
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), .closeWindow))
        menu.addItem(submenu: file, title: "File")

        // Standard selectors so text fields (tab rename, Settings) keep working; the terminal view
        // implements them through libghostty binding actions.
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), .copy))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), .paste))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), .selectAll))
        edit.addItem(.separator())
        edit.addItem(item("Clear", Action.clearTerminal, .clear))
        edit.addItem(.separator())
        // Command blocks: what each command printed, from the shell integration's marks.
        edit.addItem(item("Select Previous Command", Action.selectPreviousCommand, .selectPreviousCommand))
        edit.addItem(item("Select Next Command", Action.selectNextCommand, .selectNextCommand))
        edit.addItem(item("Copy Output", Action.copyCommandOutput, .copyOutput))
        edit.addItem(item("Copy Command", Action.copyCommandLine, .copyCommand))
        menu.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(item("Bigger", Action.biggerFont, .biggerFont))
        view.addItem(item("Smaller", Action.smallerFont, .smallerFont))
        view.addItem(item("Actual Size", Action.actualSizeFont, .actualSizeFont))
        view.addItem(.separator())
        view.addItem(item("Toggle Sidebar", Action.toggleTabListHidden, .toggleSidebar))
        view.addItem(item("Toggle Tab Layout", Action.toggleTabLayout, .toggleTabLayout))
        view.addItem(.separator())
        view.addItem(fixed("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        menu.addItem(submenu: view, title: "View")

        let window = NSMenu(title: "Window")
        window.addItem(fixed("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(item("Previous Tab", Action.previousTab, .previousTab))
        window.addItem(item("Next Tab", Action.nextTab, .nextTab))
        let goTo = NSMenu(title: "Go to Tab")
        for action in ShortcutAction.allCases {
            guard let n = action.tabNumber else { continue }
            let it = item("Tab \(n)", Action.gotoTab, action)
            it.tag = n
            goTo.addItem(it)
        }
        window.addItem(submenu: goTo, title: "Go to Tab")
        window.addItem(.separator())
        window.addItem(item("Focus Pane Left", Action.focusPaneLeft, .focusPaneLeft))
        window.addItem(item("Focus Pane Above", Action.focusPaneUp, .focusPaneUp))
        window.addItem(item("Focus Pane Right", Action.focusPaneRight, .focusPaneRight))
        window.addItem(item("Focus Pane Below", Action.focusPaneDown, .focusPaneDown))
        window.addItem(item("Equalize Panes", Action.equalizePanes, .equalizePanes))
        window.addItem(item("Zoom Pane", Action.zoomPane, .zoomPane))
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        menu.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        return menu
    }

    /// Sets `item`'s key equivalent from a shortcut.
    static func apply(_ shortcut: Shortcut, to item: NSMenuItem) {
        let equivalent = shortcut.menuKeyEquivalent(shiftedCharacter: KeyboardLayout.shiftedCharacter(for:))
        item.keyEquivalent = equivalent.key
        // Already translated for this layout; AppKit's own remapping would undo it.
        if shortcut.modifiers.contains(.shift), !equivalent.includesShift {
            item.allowsAutomaticKeyEquivalentLocalization = false
        }
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { mask.insert(.command) }
        if equivalent.includesShift { mask.insert(.shift) }
        if shortcut.modifiers.contains(.option) { mask.insert(.option) }
        if shortcut.modifiers.contains(.control) { mask.insert(.control) }
        item.keyEquivalentModifierMask = mask
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
