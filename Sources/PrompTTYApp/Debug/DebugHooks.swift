#if DEBUG
import AppKit
import IOSurface
import SwiftUI
import CommandBlocks
import GhosttyBridge
import Preferences
import PaneActivity
import WorkspaceModel

/// Named hooks for `eval` in the debug driver: things a test needs that no menu item offers.
@MainActor
enum DebugHooks {
    private static var logoWindow: NSWindow?
    private static var lastTicks: (count: Int, time: CFTimeInterval) = (0, CACurrentMediaTime())

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
        // eval logos — a window with every known program's tile and logo, for checking new logos.
        driver.hooks["logos"] = { _ in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Logos"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LogoGallery())
            window.center()
            window.orderFront(nil)
            logoWindow = window
            return "\(ProgramCatalog.all.count) programs"
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
        // eval pin <tab> [index] / unpin <tab> [index] — what the context menu and drops do.
        driver.hooks["pin"] = { args in
            guard let c = coordinator.allControllers.first, let i = args.first.flatMap(Int.init),
                  c.state.tabs.indices.contains(i) else { return "error: pin <tab> [index]" }
            c.pinTab(c.state.tabs[i].id, at: args.dropFirst().first.flatMap(Int.init))
            return ""
        }
        driver.hooks["unpin"] = { args in
            guard let c = coordinator.allControllers.first, let i = args.first.flatMap(Int.init),
                  c.state.tabs.indices.contains(i) else { return "error: unpin <tab> [index]" }
            c.unpinTab(c.state.tabs[i].id, at: args.dropFirst().first.flatMap(Int.init))
            return ""
        }
        // Sidebar projects without the sheets. Projects and tabs are indexes; tabs are the first
        // window's.
        // eval projects — each project, then each window's tabs: index, title, project.
        driver.hooks["projects"] = { _ in
            let projects = coordinator.workspace.projects
            var lines: [String] = []
            for (pi, p) in projects.enumerated() {
                lines.append("project \(pi): \(p.name)" + (p.folded ? " folded" : ""))
            }
            for (wi, controller) in coordinator.allControllers.enumerated() {
                for (ti, t) in controller.state.tabs.enumerated() {
                    let projectID: ProjectID? = controller.state.project(of: t)
                    var index = "-"
                    if let i = projects.firstIndex(where: { $0.id == projectID }) { index = String(i) }
                    lines.append("window \(wi) tab \(ti): \(t.listTitle.debugDescription) project=\(index)" + (t.pin != nil ? " pinned" : ""))
                }
            }
            return lines.joined(separator: "\n")
        }
        // eval projectadd <name> [tab] — New Project…, moving the tab into it.
        driver.hooks["projectadd"] = { args in
            guard let c = coordinator.allControllers.first, let name = args.first else { return "error: projectadd <name> [tab]" }
            var tab: TabID?
            if let i = args.dropFirst().first.flatMap(Int.init), c.state.tabs.indices.contains(i) { tab = c.state.tabs[i].id }
            coordinator.addProject(name: name, adding: tab)
            return ""
        }
        // eval projecttab <tab> <project|none> — Move to Project.
        driver.hooks["projecttab"] = { args in
            let projects = coordinator.workspace.projects
            guard let c = coordinator.allControllers.first, args.count == 2, let i = Int(args[0]),
                  c.state.tabs.indices.contains(i) else { return "error: projecttab <tab> <project|none>" }
            var project: ProjectID?
            if let p = Int(args[1]), projects.indices.contains(p) { project = projects[p].id }
            c.placeTab(c.state.tabs[i].id, inProject: project)
            return ""
        }
        // eval projectnewtab <project> — the header's "+".
        driver.hooks["projectnewtab"] = { args in
            let projects = coordinator.workspace.projects
            guard let c = coordinator.allControllers.first, let p = args.first.flatMap(Int.init),
                  projects.indices.contains(p) else { return "error: projectnewtab <project>" }
            c.newTab(inProject: projects[p].id)
            return ""
        }
        // eval projectfold <project> on|off
        driver.hooks["projectfold"] = { args in
            let projects = coordinator.workspace.projects
            guard let c = coordinator.allControllers.first, args.count == 2, let p = Int(args[0]),
                  projects.indices.contains(p) else { return "error: projectfold <project> on|off" }
            c.setProjectFolded(projects[p].id, args[1] == "on")
            return ""
        }
        // eval projectmove <project> <index> — a header dropped on another's (Move Up/Down: ±1).
        driver.hooks["projectmove"] = { args in
            let projects = coordinator.workspace.projects
            guard let c = coordinator.allControllers.first, args.count == 2, let p = Int(args[0]), let to = Int(args[1]),
                  projects.indices.contains(p) else { return "error: projectmove <project> <index>" }
            c.moveProject(projects[p].id, to: to)
            return ""
        }
        // eval projectrename <project> <name…>
        driver.hooks["projectrename"] = { args in
            let projects = coordinator.workspace.projects
            guard args.count >= 2, let p = Int(args[0]), projects.indices.contains(p) else { return "error: projectrename <project> <name>" }
            coordinator.renameProject(projects[p].id, to: args.dropFirst().joined(separator: " "))
            return ""
        }
        // eval projectremove <project> — Remove Project, without asking.
        driver.hooks["projectremove"] = { args in
            let projects = coordinator.workspace.projects
            guard let p = args.first.flatMap(Int.init), projects.indices.contains(p) else { return "error: projectremove <project>" }
            coordinator.removeProject(projects[p].id)
            return ""
        }
        // eval resetpin <tab> — Reset Pinned Tab.
        driver.hooks["resetpin"] = { args in
            guard let c = coordinator.allControllers.first, let i = args.first.flatMap(Int.init),
                  c.state.tabs.indices.contains(i) else { return "error: resetpin <tab>" }
            c.resetPinnedTab(c.state.tabs[i].id)
            return ""
        }
        // eval pincommand <tab> <command…> — Edit Pinned Command… without the sheet.
        driver.hooks["pincommand"] = { args in
            guard let c = coordinator.allControllers.first, let i = args.first.flatMap(Int.init),
                  c.state.tabs.indices.contains(i) else { return "error: pincommand <tab> <command>" }
            coordinator.setPinnedCommand(c.state.tabs[i].id, args.dropFirst().joined(separator: " "))
            return ""
        }
        // eval pinicon <tab> <symbol> <color> | pinicon <tab> default — Change Icon… without the popover.
        driver.hooks["pinicon"] = { args in
            guard let c = coordinator.allControllers.first, let i = args.first.flatMap(Int.init),
                  c.state.tabs.indices.contains(i), args.count >= 2 else { return "error: pinicon <tab> <symbol> <color>|default" }
            let icon = args[1] == "default" ? nil : PinIcon(symbol: args[1], color: args.count > 2 ? PinIcon.Color(rawValue: args[2]) ?? .dark : .dark)
            c.setPinnedIcon(c.state.tabs[i].id, icon)
            return ""
        }
        // eval iconpicker <tab>|off — opens or closes a pinned tab's icon picker.
        driver.hooks["iconpicker"] = { args in
            guard let c = coordinator.allControllers.first else { return "error: no window" }
            c.chrome.iconPickerTab = args.first.flatMap(Int.init).flatMap { c.state.tabs.indices.contains($0) ? c.state.tabs[$0].id : nil }
            return ""
        }
        // eval pins — each tab's pin.
        driver.hooks["pins"] = { _ in
            guard let c = coordinator.allControllers.first else { return "error: no window" }
            return c.state.tabs.enumerated().map { i, t in
                "\(i) \(t.listTitle): " + (t.pin.map { "pinned dir=\(Tab.abbreviate($0.directory)) command=\($0.command ?? "-") icon=\($0.icon.map { "\($0.symbol)/\($0.color.rawValue)" } ?? "-")" } ?? "-")
            }.joined(separator: "\n")
        }
        // eval tabdrag <tab>|off — a tab drag in progress, for the pin drop tile.
        driver.hooks["tabdrag"] = { args in
            guard let c = coordinator.allControllers.first else { return "error: no window" }
            if let i = args.first.flatMap(Int.init), c.state.tabs.indices.contains(i) {
                c.chrome.draggingTab = c.state.tabs[i].id
            } else {
                c.chrome.draggingTab = nil
            }
            return ""
        }
        // eval preview <tab>|off — show a tab's sidebar preview without hovering.
        driver.hooks["preview"] = { args in
            guard let c = coordinator.allControllers.first else { return "error: no window" }
            if let i = args.first.flatMap(Int.init), c.state.tabs.indices.contains(i) {
                c.chrome.forcedPreview = c.state.tabs[i].id
            } else {
                c.chrome.forcedPreview = nil
            }
            return ""
        }
        // eval peek on|off — the collapsed sidebar peeks in without hovering.
        driver.hooks["peek"] = { args in
            for c in coordinator.allControllers { c.chrome.forcedPeek = args.first == "on" }
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
        // eval hz — the refresh rate granted to the key window's display link over the last second
        // (0 when the full-rate setting is off or the window is not in front).
        driver.hooks["hz"] = { args in
            guard let c = coordinator.allControllers.first(where: { $0.window?.isKeyWindow == true }) ?? coordinator.allControllers.first else { return "error: no window" }
            if let arg = args.first {
                c.forceFullRefreshRate = arg == "force"
                c.updateRefreshRate()
            }
            // Ticks since the last call: run `eval hz`, `wait 1`, `eval hz` for a rate.
            let now = CACurrentMediaTime()
            let ticks = c.refreshTicks - DebugHooks.lastTicks.count
            let elapsed = now - DebugHooks.lastTicks.time
            DebugHooks.lastTicks = (c.refreshTicks, now)
            let before = c.refreshTicks - ticks
            let start = now - elapsed
            let state = "setting=\(coordinator.preferences.settings.fullRefreshRate) active=\(NSApp.isActive) key=\(c.window?.isKeyWindow == true) visible=\(c.window?.occlusionState.contains(.visible) == true)"
            return String(format: "hz=%.0f ", Double(c.refreshTicks - before) / (CACurrentMediaTime() - start)) + state
        }
        // eval layers — the focused terminal's layer tree (class, frame, contents type).
        driver.hooks["layers"] = { _ in
            guard let view = driver.focusedSurface(), let layer = view.layer else { return "error: no terminal" }
            func describe(_ l: CALayer, _ depth: Int) -> [String] {
                var contents = l.contents.map { String(describing: type(of: $0)) } ?? "-"
                if let c = l.contents, CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() {
                    let surface = unsafeBitCast(c as AnyObject, to: IOSurfaceRef.self)
                    contents += " \(IOSurfaceGetWidth(surface))x\(IOSurfaceGetHeight(surface))"
                }
                let b = l.bounds
                let expected = "\(Int(b.width * l.contentsScale))x\(Int(b.height * l.contentsScale))"
                return ["\(String(repeating: "  ", count: depth))\(type(of: l)) bounds=\(b.width)x\(b.height) scale=\(l.contentsScale) accepts=\(expected) contents=\(contents)"]
                    + (l.sublayers ?? []).flatMap { describe($0, depth + 1) }
            }
            return describe(layer, 0).joined(separator: "\n")
        }
        // eval fps start | fps stop — counts new frames (layer contents set) in the focused terminal.
        driver.hooks["fps"] = { args in
            guard let view = driver.focusedSurface(), let layer = view.layer else { return "error: no terminal" }
            let target = layer.sublayers?.first { $0.contents != nil } ?? layer
            if args.first == "start" {
                FrameCounter.shared.start(on: target)
                return "counting on \(type(of: target))"
            }
            return FrameCounter.shared.stop()
        }
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
            return "bar=\(shell.bar) phase=\(shell.phase) mode=\(tv.vi.mode) text=\(tv.string.debugDescription) caret=\(tv.selectedRange().location) ghost=\((tv.suggestion ?? "-").debugDescription) height=\(shell.editorHeight) keys=\(who) scroll=\(NSStringFromRect(shell.editor.frame)) tv=\(NSStringFromRect(tv.frame)) container=\(NSStringFromSize(tv.textContainer?.size ?? .zero)) inWindow=\(tv.window != nil) host=\(shell.editor.superview.map { NSStringFromRect($0.frame) } ?? "-") color=\(String(describing: tv.textColor)) caretColor=\(tv.insertionPointColor.usingColorSpace(.sRGB).map { String(format: "#%02X%02X%02X", Int(($0.redComponent * 255).rounded()), Int(($0.greenComponent * 255).rounded()), Int(($0.blueComponent * 255).rounded())) } ?? "-")"
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
        // eval blocks — the focused pane's command blocks, viewport, selection and overlay.
        driver.hooks["blocks"] = { _ in
            guard let c = coordinator.allControllers.first(where: { $0.window?.isKeyWindow == true }) ?? coordinator.allControllers.first,
                  let overlay = c.focusedBlocks else { return "error: no overlay" }
            overlay.refresh()
            return overlay.debugDescription
        }
        // eval scrollrow <row> — scrolls the focused terminal so that scrollback row is at the top.
        driver.hooks["scrollrow"] = { args in
            guard let c = coordinator.allControllers.first(where: { $0.window?.isKeyWindow == true }) ?? coordinator.allControllers.first,
                  let surface = c.focusedSurface, let row = args.first.flatMap(Int.init) else { return "error: scrollrow row" }
            surface.scroll(toRow: row)
            return ""
        }
        // eval blocksoff <0|1> — stops (1) or resumes (0) reading blocks; resets the read timer.
        driver.hooks["blocksoff"] = { args in
            BlockOverlayView.disabled = args.first == "1"
            BlockOverlayView.readTime = 0
            BlockOverlayView.reads = 0
            return ""
        }
        // eval mousemove <x> <y> — moves the pointer (window points, top-left origin) as a mouse-moved event.
        driver.hooks["mousemove"] = { args in
            let nums = args.compactMap(Double.init)
            guard nums.count == 2, let window = DebugDriver.targetWindow else { return "error: mousemove x y" }
            let p = NSPoint(x: nums[0], y: window.frame.height - nums[1])
            guard let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return "error: event" }
            // AppKit only routes real pointer moves to tracking areas; hand it to the terminal under it.
            guard let surface = window.contentView?.hitTest(p) as? TerminalSurfaceView else { return "error: no terminal at \(nums)" }
            surface.mouseMoved(with: e)
            return ""
        }
        // eval pasteboard — the general pasteboard's string.
        driver.hooks["pasteboard"] = { _ in NSPasteboard.general.string(forType: .string).map { $0.debugDescription } ?? "nil" }
        // eval blocktext <row> <command|output|all> — the text of the block on that row.
        driver.hooks["blocktext"] = { args in
            guard let c = coordinator.allControllers.first(where: { $0.window?.isKeyWindow == true }) ?? coordinator.allControllers.first,
                  let surface = c.focusedSurface, let row = args.first.flatMap(Int.init) else { return "error: blocktext row part" }
            let part: BlockPart = switch args.dropFirst().first { case "command": .command; case "all": .all; default: .output }
            return surface.blockText(row: row, part: part).map { $0.debugDescription } ?? "nil"
        }
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
            case "vim": coordinator.preferences.update { $0.vimNavigation = args[1] == "on" }
            case "fullrate": coordinator.preferences.update { $0.fullRefreshRate = args[1] == "on" }
            case "cursor":
                let value: CursorColor = switch args[1] {
                case "accent": .accent
                case let hex where hex.hasPrefix("#"): UInt32(hex.dropFirst(), radix: 16).map(CursorColor.custom) ?? .theme
                default: .theme
                }
                coordinator.preferences.update { $0.cursorColor = value }
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
/// Every program's tile as the tab rows show it, and its logo as the pane header does.
private struct LogoGallery: View {
    var body: some View {
        let programs = ProgramCatalog.all.filter { $0.logo != nil }
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 10), spacing: 10) {
            ForEach(programs, id: \.id) { program in
                VStack(spacing: 5) {
                    ProgramStack(cards: [.init(id: program.id, program: program, display: .idle)])
                        .scaleEffect(2)
                        .frame(height: 38)
                    ProgramIcon(program: program, size: 16)
                    Text(program.name)
                        .font(.system(size: 9))
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(width: 960, height: 720, alignment: .top)
        .background(Color(white: 0.16))
        .environment(\.colorScheme, .dark)
    }
}
/// Counts a layer's `contents` changes: the frames the terminal presents.
@MainActor
final class FrameCounter: NSObject {
    static let shared = FrameCounter()
    private var observation: NSKeyValueObservation?
    private var frames: [CFTimeInterval] = []
    private var started: CFTimeInterval = 0

    func start(on layer: CALayer) {
        frames = []
        started = CACurrentMediaTime()
        observation = layer.observe(\.contents, options: [.new]) { [weak self] _, _ in
            let now = CACurrentMediaTime()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.frames.append(now) } }
        }
    }

    func stop() -> String {
        observation = nil
        let elapsed = CACurrentMediaTime() - started
        // The frame times, for comparing with when a program wrote its output.
        if let dir = ProcessInfo.processInfo.environment["PROMPTTY_DEBUG_DIR"] {
            try? frames.map { String(format: "%.6f", $0) }.joined(separator: "\n")
                .write(toFile: dir + "/frames.txt", atomically: true, encoding: .utf8)
        }
        let gaps = zip(frames.dropFirst(), frames).map { ($0 - $1) * 1000 }.sorted()
        func pct(_ p: Double) -> String { gaps.isEmpty ? "-" : String(format: "%.1f", gaps[min(gaps.count - 1, Int(Double(gaps.count) * p))]) }
        return String(format: "frames=%d in %.1fs (%.1f fps) gap ms p50=%@ p90=%@ p99=%@ max=%@", frames.count, elapsed, Double(frames.count) / elapsed,
                      pct(0.5), pct(0.9), pct(0.99), gaps.last.map { String(format: "%.1f", $0) } ?? "-")
    }
}
#endif
