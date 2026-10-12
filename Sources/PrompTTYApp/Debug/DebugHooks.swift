#if DEBUG
import AppKit
import SwiftUI
import GhosttyBridge
import WorkspaceModel

/// Named hooks for `eval` in the debug driver: things a test needs that no menu item offers.
@MainActor
enum DebugHooks {
    static func install(on driver: DebugDriver, coordinator: WorkspaceCoordinator) {
        // eval activity — each pane's activity in the key window (tab.pane: display program) and
        // the notices posted since the last call.
        driver.hooks["activity"] = { _ in
            var lines: [String] = []
            for c in coordinator.allControllers {
                for (ti, tab) in c.state.tabs.enumerated() {
                    for (pi, pane) in tab.orderedPanes.enumerated() {
                        let a = coordinator.activity.activity(for: pane.id)
                        lines.append("\(ti).\(pi): \(a.display) program=\(a.program?.id ?? "-") title=\(pane.title.debugDescription)")
                    }
                }
            }
            lines += coordinator.postedNotices.map { "notice: \($0)" }
            coordinator.postedNotices = []
            return lines.joined(separator: "\n")
        }
        // eval reveal <tab> — what clicking a notification about that tab's first pane does.
        driver.hooks["reveal"] = { args in
            guard let c = coordinator.allControllers.first, let i = args.first.flatMap(Int.init),
                  c.state.tabs.indices.contains(i), let pane = c.state.tabs[i].orderedPanes.first else { return "error: reveal <tab>" }
            coordinator.reveal(pane.id)
            return ""
        }
        // eval dropfiles <path>… — files dropped on the focused pane's terminal (its drop handler).
        driver.hooks["dropfiles"] = { args in
            guard let view = driver.focusedSurface(), let drop = view.onFileDrop else { return "error: no drop handler" }
            return drop(args.map { URL(fileURLWithPath: $0) }) ? "" : "declined"
        }
        // eval headers on|off — show every pane header without hovering.
        driver.hooks["headers"] = { args in
            for c in coordinator.allControllers { c.chrome.forceHeaders = args.first == "on" }
            return ""
        }
        // eval movepane <srcTab> <srcPane> <dstTab> <dstPane> <left|right|top|bottom> — indices in the key window.
        driver.hooks["movepane"] = { args in
            guard args.count == 5, let w = keyState(coordinator),
                  let st = Int(args[0]), let sp = Int(args[1]), let dt = Int(args[2]), let dp = Int(args[3]),
                  st < w.tabs.count, dt < w.tabs.count,
                  sp < w.tabs[st].root.leaves.count, dp < w.tabs[dt].root.leaves.count,
                  let edge = edge(args[4]) else { return "error: movepane srcTab srcPane dstTab dstPane edge" }
            coordinator.movePane(w.tabs[st].root.leaves[sp], to: w.tabs[dt].root.leaves[dp], edge: edge)
            return ""
        }
        // eval moveintotab <srcTab> <srcPane> <dstTab>
        driver.hooks["moveintotab"] = { args in
            guard args.count == 3, let w = keyState(coordinator),
                  let st = Int(args[0]), let sp = Int(args[1]), let dt = Int(args[2]),
                  st < w.tabs.count, dt < w.tabs.count, sp < w.tabs[st].root.leaves.count else { return "error: moveintotab srcTab srcPane dstTab" }
            coordinator.movePane(w.tabs[st].root.leaves[sp], intoTab: w.tabs[dt].id)
            return ""
        }
        // eval movetowindow <srcWindow> <srcPane> <dstWindow> — move a pane of one window's selected tab
        // next to the focused pane of another window's selected tab.
        driver.hooks["movetowindow"] = { args in
            let windows = coordinator.workspace.windows
            guard args.count == 3, let sw = Int(args[0]), let sp = Int(args[1]), let dw = Int(args[2]),
                  sw < windows.count, dw < windows.count, let tab = windows[sw].selectedTab,
                  sp < tab.root.leaves.count,
                  let target = windows[dw].selectedTab else { return "error: movetowindow srcWindow srcPane dstWindow" }
            coordinator.movePane(tab.root.leaves[sp], to: target.focusedPaneID, edge: .right)
            return ""
        }
        // eval exit — mark the focused pane's process as exited (shows the overlay).
        driver.hooks["exited"] = { args in
            guard let c = coordinator.allControllers.first(where: { $0.window?.isKeyWindow == true }) ?? coordinator.allControllers.first,
                  let tab = c.state.selectedTab else { return "error: no window" }
            c.chrome.exitedPanes[tab.focusedPaneID] = UInt32(args.first ?? "0") ?? 0
            return ""
        }
        // eval menukey <title> — print a menu item's key equivalent and test it against a synthesized event.
        driver.hooks["menukey"] = { args in
            let title = args.joined(separator: " ")
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.title == title { return item }
                    if let sub = item.submenu, let found = find(sub) { return found }
                }
                return nil
            }
            guard let menu = NSApp.mainMenu, let item = find(menu) else { return "error: no item \(title)" }
            let scalars = item.keyEquivalent.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            return "keyEquivalent=\(scalars) mask=\(item.keyEquivalentModifierMask.rawValue) enabled=\(item.isEnabled) target=\(String(describing: item.target)) action=\(String(describing: item.action))"
        }
        // eval keyprobe <spec> — show the synthesized event and whether the main menu claims it.
        driver.hooks["keyprobe"] = { args in
            guard let spec = args.first, let e = KeySpec.events(spec, window: NSApp.keyWindow)?.first else { return "error: keyprobe spec" }
            let chars = (e.characters ?? "").unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            let ign = (e.charactersIgnoringModifiers ?? "").unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            let claimed = NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
            return "chars=\(chars) ignoring=\(ign) flags=\(e.modifierFlags.rawValue) menuClaimed=\(claimed)"
        }
        // eval matrix — which key-equivalent spellings match which ⇧⌘D event spellings.
        driver.hooks["matrix"] = { _ in
            final class Sink: NSObject { @objc func hit(_ s: Any?) {} }
            let sink = Sink()
            var lines: [String] = []
            let items: [(String, NSEvent.ModifierFlags)] = [("d", [.command, .shift]), ("D", [.command]), ("D", [.command, .shift])]
            let events: [(String, String)] = [("d", "D"), ("D", "D"), ("D", "d"), ("d", "d")]
            for (key, mask) in items {
                for (chars, ignoring) in events {
                    let menu = NSMenu()
                    let item = NSMenuItem(title: "x", action: #selector(Sink.hit(_:)), keyEquivalent: key)
                    item.keyEquivalentModifierMask = mask
                    item.target = sink
                    menu.addItem(item)
                    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                             windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                                             characters: chars, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: 2)!
                    lines.append("item=\(key) mask=\(mask.contains(.shift) ? "cmd+shift" : "cmd") event chars=\(chars) ign=\(ignoring) -> \(menu.performKeyEquivalent(with: e))")
                }
            }
            return lines.joined(separator: "\n")
        }
        // eval hit x y — the AppKit view under a window point (top-left origin).
        driver.hooks["hit"] = { args in
            guard args.count == 2, let x = Double(args[0]), let y = Double(args[1]),
                  let window = DebugDriver.inputWindow,
                  let content = window.contentView,
                  let root = content.superview else { return "error: hit x y" }
            let point = NSPoint(x: x, y: window.frame.height - y)
            let hit = root.hitTest(point)
            var chain: [String] = []
            var v = hit
            while let view = v, chain.count < 6 {
                chain.append("\(type(of: view)) \(NSStringFromRect(view.frame))")
                v = view.superview
            }
            return chain.joined(separator: "\n  <- ")
        }
        // eval droptarget <pane> <edge> | off — show a pane's drop highlight in the key window's selected tab.
        driver.hooks["droptarget"] = { args in
            guard let c = coordinator.allControllers.first(where: { $0.window?.isKeyWindow == true }) ?? coordinator.allControllers.first,
                  let tab = c.state.selectedTab else { return "error: no window" }
            if args.first == "off" { c.chrome.dropTarget = nil; return "" }
            guard args.count == 2, let i = Int(args[0]), i < tab.root.leaves.count, let e = edge(args[1]) else { return "error: droptarget pane edge" }
            c.chrome.dropTarget = (tab.root.leaves[i], e)
            return ""
        }
        // eval themelist <Theme_Name> [dark|light] — render the theme list in a plain window (popovers
        // close at once in an inactive app, so the real one cannot be captured).
        driver.hooks["themelist"] = { args in
            final class Box { var value: String; init(_ v: String) { value = v } }
            let box = Box(args.first?.replacingOccurrences(of: "_", with: " ") ?? "Flexoki Dark")
            let list = ThemeList(
                selection: Binding(get: { box.value }, set: { box.value = $0 }),
                swatches: ThemeSwatches(catalog: coordinator.preferences.themes),
                prefersDark: args.count > 1 ? args[1] == "dark" : nil,
                onPick: {}
            )
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "ThemeList"
            window.contentView = NSHostingView(rootView: list)
            window.isReleasedWhenClosed = false
            window.orderFront(nil)
            return ""
        }
        // eval sheet [buttonIndex] — describe the attached alert sheet, optionally pressing a button.
        driver.hooks["sheet"] = { args in
            for c in coordinator.allControllers {
                guard let sheet = c.window?.attachedSheet else { continue }
                let texts = sheet.contentView.map(Self.texts(in:)) ?? []
                if let i = args.first.flatMap(Int.init) {
                    let buttons = sheet.contentView.map(Self.buttons(in:)) ?? []
                    guard i < buttons.count else { return "error: no button \(i)" }
                    buttons[i].performClick(nil)
                }
                return "sheet: " + texts.joined(separator: " | ")
            }
            return "no sheet"
        }
        // eval realmenu <spec> <Menu Title> — does AppKit's own NSMenu match a layout-true key press
        // against that main-menu item's key equivalent? (Copies the item into a scratch menu with a
        // target, so the match does not depend on the app being active.)
        driver.hooks["realmenu"] = { args in
            guard args.count >= 2 else { return "error: realmenu spec title" }
            let title = args.dropFirst().joined(separator: " ")
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.title == title { return item }
                    if let sub = item.submenu, let found = find(sub) { return found }
                }
                return nil
            }
            guard let original = NSApp.mainMenu.flatMap(find),
                  let event = KeySpec.events(args[0], window: NSApp.orderedWindows.first)?.first else { return "error: no item or key" }
            final class Sink: NSObject { var hit = false; @objc func fire(_ s: Any?) { hit = true } }
            let sink = Sink()
            let menu = NSMenu()
            let copy = NSMenuItem(title: title, action: #selector(Sink.fire(_:)), keyEquivalent: original.keyEquivalent)
            copy.keyEquivalentModifierMask = original.keyEquivalentModifierMask
            copy.allowsAutomaticKeyEquivalentLocalization = original.allowsAutomaticKeyEquivalentLocalization
            copy.target = sink
            menu.addItem(copy)
            _ = menu.performKeyEquivalent(with: event)
            let k = original.keyEquivalent.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined()
            return "item=\(k) mask=\(original.keyEquivalentModifierMask.rawValue) event=\(event.charactersIgnoringModifiers ?? "") matched=\(sink.hit)"
        }
        // eval sysitem — add a Ctrl-only menu item (Ctrl+F12), standing in for the system-provided
        // Globe/fn items AppKit inserts (Move & Resize, Emoji & Symbols); eval sysitem hit reports it.
        driver.hooks["sysitem"] = { args in
            if args.first == "hit" { return "sysitem hit=\(SystemItemSink.shared.hits)" }
            let item = NSMenuItem(title: "Debug System Item", action: #selector(SystemItemSink.fire(_:)), keyEquivalent: String(Character(UnicodeScalar(0xF70F)!)))
            item.keyEquivalentModifierMask = [.control]
            item.target = SystemItemSink.shared
            NSApp.mainMenu?.items.last?.submenu?.addItem(item)
            return ""
        }
        // eval resizes — terminal resizes since the last call (each layout change should cost one per pane).
        driver.hooks["resizes"] = { _ in
            defer { TerminalSurfaceView.sentSizes = [] }
            return "resizes=\(TerminalSurfaceView.sentSizes.count) \(TerminalSurfaceView.sentSizes.joined(separator: " "))"
        }
        // eval shell — the focused pane's shell session: phase, header data, what the shell reported.
        driver.hooks["shell"] = { _ in
            guard let c = coordinator.allControllers.first(where: { $0.window?.isKeyWindow == true }) ?? coordinator.allControllers.first,
                  let tab = c.state.selectedTab, let shell = c.shell(for: tab.focusedPaneID) else { return "error: no shell" }
            let exit = shell.state.lastExit.map { "\($0.code)/\(String(format: "%.2f", $0.duration))s" } ?? "-"
            let git = shell.git.map { "\($0.branch)\($0.dirty ? "*" : "")" } ?? "-"
            let file = shell.stateFile.map { "histfile=\($0.historyFile ?? "-") path=\($0.path.count) names=\($0.commandNames.count) exports=\($0.exports.count)" } ?? "no-state-file"
            return "phase=\(shell.phase) integrated=\(shell.integrated) pid=\(shell.state.shellPID ?? -1) fg=\(shell.surface?.foregroundPID ?? -1) dir=\(shell.directory) git=\(git) exit=\(exit) history=\(shell.history.newestFirst.count) \(file)"
        }
        // eval bar — the focused pane's input bar: presentation, text, and who has the keys.
        driver.hooks["bar"] = { _ in
            guard let c = coordinator.allControllers.first(where: { $0.window?.isKeyWindow == true }) ?? coordinator.allControllers.first,
                  let tab = c.state.selectedTab, let shell = c.shell(for: tab.focusedPaneID) else { return "error: no shell" }
            let responder = c.window?.firstResponder
            let who = responder === shell.editor.textView ? "bar" : (responder is TerminalSurfaceView ? "terminal" : String(describing: type(of: responder as Any)))
            let tv = shell.editor.textView
            return "bar=\(shell.bar) phase=\(shell.phase) mode=\(tv.vi.mode) text=\(tv.string.debugDescription) caret=\(tv.selectedRange().location) ghost=\((tv.suggestion ?? "-").debugDescription) height=\(shell.editorHeight) keys=\(who) scroll=\(NSStringFromRect(shell.editor.frame)) tv=\(NSStringFromRect(tv.frame)) container=\(NSStringFromSize(tv.textContainer?.size ?? .zero)) inWindow=\(tv.window != nil) host=\(shell.editor.superview.map { NSStringFromRect($0.frame) } ?? "-") color=\(String(describing: tv.textColor))"
        }
        // eval bartext <text> — puts text in the focused pane's bar, as if typed (any keyboard layout).
        driver.hooks["bartext"] = { args in
            guard let c = coordinator.allControllers.first(where: { $0.window?.isKeyWindow == true }) ?? coordinator.allControllers.first,
                  let tab = c.state.selectedTab, let shell = c.shell(for: tab.focusedPaneID) else { return "error: no shell" }
            shell.editor.textView.insertText(args.joined(separator: " "), replacementRange: shell.editor.textView.selectedRange())
            return ""
        }
        // eval clip <text> — puts text on the general pasteboard.
        driver.hooks["clip"] = { args in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(args.joined(separator: " "), forType: .string)
            return ""
        }
        // eval windows — every window: class, frame, visibility, title.
        driver.hooks["windows"] = { _ in
            NSApp.windows.map { "\(type(of: $0)) \(NSStringFromRect($0.frame)) visible=\($0.isVisible) key=\($0.isKeyWindow) \"\($0.title)\"" }.joined(separator: "\n")
        }
        driver.hooks["live"] = { _ in "controllers=\(TerminalWindowController.liveCount)" }
        // eval backdrop — window transparency and the blur view's state, for checking the chrome.
        driver.hooks["backdrop"] = { _ in
            guard let window = coordinator.allControllers.first?.window else { return "error: no window" }
            var lines = ["window opaque=\(window.isOpaque) bg=\(window.backgroundColor.description.prefix(60)) appearance=\(window.effectiveAppearance.name.rawValue)"]
            func walk(_ view: NSView, depth: Int) {
                if let fx = view as? NSVisualEffectView {
                    lines.append("blur frame=\(NSStringFromRect(fx.frame)) material=\(fx.material.rawValue) blending=\(fx.blendingMode.rawValue) state=\(fx.state.rawValue) hidden=\(fx.isHiddenOrHasHiddenAncestor) inWindow=\(fx.window != nil)")
                }
                if depth < 3, let layer = view.layer, let bg = layer.backgroundColor, bg.alpha > 0 {
                    lines.append("\(String(repeating: " ", count: depth))opaque-ish layer bg alpha=\(bg.alpha) on \(type(of: view)) frame=\(NSStringFromRect(view.frame))")
                }
                for sub in view.subviews { walk(sub, depth: depth + 1) }
            }
            if let frameView = window.contentView?.superview { walk(frameView, depth: 0) }
            return lines.joined(separator: "\n")
        }
        driver.hooks["banner"] = { args in
            coordinator.showTransientBanner(args.joined(separator: " "))
            return ""
        }
        driver.hooks["settings"] = { args in
            // eval settings <key> <value> for a few app settings.
            guard args.count == 2 else { return "error: settings key value" }
            switch args[0] {
            case "sidebarWidth": coordinator.preferences.update { $0.sidebarWidth = Double(args[1]) ?? 220 }
            case "tintStrength": coordinator.preferences.update { $0.tintStrength = Double(args[1]) ?? 0.5 }
            case "follow": coordinator.preferences.update { $0.followSystemAppearance = args[1] == "on" }
            case "theme": coordinator.preferences.update { $0.theme = args[1].replacingOccurrences(of: "_", with: " ") }
            default: return "error: unknown setting"
            }
            return ""
        }
    }

    @MainActor final class SystemItemSink: NSObject {
        static let shared = SystemItemSink()
        var hits = 0
        @objc func fire(_ sender: Any?) { hits += 1 }
    }

    private static func texts(in view: NSView) -> [String] {
        var out: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty { out.append(field.stringValue) }
        if let button = view as? NSButton, !button.title.isEmpty { out.append("[\(button.title)]") }
        for sub in view.subviews { out += texts(in: sub) }
        return out
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        var out: [NSButton] = []
        if let b = view as? NSButton, !b.title.isEmpty { out.append(b) }
        for sub in view.subviews { out += buttons(in: sub) }
        return out
    }

    private static func keyState(_ coordinator: WorkspaceCoordinator) -> WindowState? {
        (coordinator.allControllers.first(where: { $0.window?.isKeyWindow == true }) ?? coordinator.allControllers.first)?.state
    }

    private static func edge(_ s: String) -> PaneEdge? {
        switch s {
        case "left": return .left
        case "right": return .right
        case "top": return .top
        case "bottom": return .bottom
        default: return nil
        }
    }
}
#endif
