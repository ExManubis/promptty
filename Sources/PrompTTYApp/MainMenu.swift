import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let menu = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About PrompTTY", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Reload Configuration", action: #selector(AppDelegate.reloadConfig(_:)), keyEquivalent: ",").keyEquivalentModifierMask = [.command, .shift]
        app.addItem(.separator())
        app.addItem(withTitle: "Hide PrompTTY", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit PrompTTY", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(submenu: app, title: "PrompTTY")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "New Tab", action: #selector(TerminalWindowController.newTab(_:)), keyEquivalent: "t")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(TerminalWindowController.closeTab(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w").keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(submenu: file, title: "File")

        // ⌘C/⌘V in the terminal never reach these: the surface is first responder and libghostty
        // consumes them in `keyDown` (its default `super+c`/`super+v` binds). These items serve text
        // fields such as the inline tab rename.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Tab Layout", action: #selector(AppDelegate.toggleTabLayout(_:)), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
        view.addItem(withTitle: "Hide Tab List", action: #selector(AppDelegate.toggleTabListHidden(_:)), keyEquivalent: "b")
        view.addItem(.separator())
        view.addItem(withTitle: "Previous Tab", action: #selector(TerminalWindowController.previousTab(_:)), keyEquivalent: "[").keyEquivalentModifierMask = [.command, .shift]
        view.addItem(withTitle: "Next Tab", action: #selector(TerminalWindowController.nextTab(_:)), keyEquivalent: "]").keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        menu.addItem(submenu: view, title: "View")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        menu.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        return menu
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
