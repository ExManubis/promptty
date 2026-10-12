#if DEBUG
import AppKit
import GhosttyBridge

/// Debug-only automation for verifying the app without Screen Recording or Accessibility access.
///
/// Launch with `PROMPTTY_DEBUG_DIR=<dir>`, write commands to `<dir>/commands.txt`, then send
/// `SIGUSR1`. Commands run in order; output goes to `<dir>/results.txt`, and `<dir>/done` appears
/// when the batch finishes. See `script/drive`.
///
///     wait 0.5                 sleep
///     action newTab:           send an action through the responder chain
///     key ctrl+return          synthesize a key press (goes through menus and key equivalents)
///     type ls\n                send text to the focused terminal (\n and \t are unescaped)
///     text out.txt             write the focused terminal's visible text to <dir>/out.txt
///     state                    append the model state (from `stateProvider`) to results
///     snapshot name            write each window to <dir>/name-<i>.png
///     appearance dark|light|system
///     eval <name> [args]       run a named hook registered in `hooks`
///     quit
@MainActor
final class DebugDriver {
    static let shared = DebugDriver()

    let directory: URL?
    var stateProvider: (() -> String)?
    var hooks: [String: ([String]) -> String] = [:]
    private var source: DispatchSourceSignal?
    private var quitRequested = false

    private init() {
        if let dir = ProcessInfo.processInfo.environment["PROMPTTY_DEBUG_DIR"], !dir.isEmpty {
            directory = URL(fileURLWithPath: dir, isDirectory: true)
        } else {
            directory = nil
        }
    }

    func install() {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.runBatch() }
        }
        source.resume()
        self.source = source
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: directory.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
    }

    private func runBatch() {
        guard let directory else { return }
        let done = directory.appendingPathComponent("done")
        try? FileManager.default.removeItem(at: done)
        let commands = (try? String(contentsOf: directory.appendingPathComponent("commands.txt"), encoding: .utf8)) ?? ""
        NSApp.activate()
        NSApp.orderedWindows.first?.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            var out: [String] = []
            for raw in commands.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(raw)
                if line.hasPrefix("#") { continue }
                out.append("> \(line)")
                let result = await self.run(line)
                if !result.isEmpty { out.append(result) }
            }
            try? out.joined(separator: "\n").appending("\n").write(to: directory.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
            FileManager.default.createFile(atPath: done.path, contents: nil)
            if self.quitRequested { NSApp.terminate(nil) }
        }
    }

    private func run(_ line: String) async -> String {
        guard let directory else { return "" }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""
        switch command {
        case "wait":
            try? await Task.sleep(for: .seconds(Double(arg) ?? 0.5))
            return ""
        case "action":
            let selector = NSSelectorFromString(arg)
            guard let window = DebugDriver.targetWindow,
                  let target = Self.responder(for: selector, in: window) else { return "error: no target for \(arg)" }
            NSApp.sendAction(selector, to: target, from: nil)
            return ""
        case "key":
            let window = DebugDriver.targetWindow
            guard let events = KeySpec.events(arg, window: window) else { return "error: bad key \(arg)" }
            for e in events { Self.dispatch(e, to: window) }
            return ""
        case "keys":
            // Types `arg` as individual key presses into whatever has focus (text fields too).
            let window = DebugDriver.targetWindow
            for ch in arg {
                let s = String(ch)
                let spec = s == " " ? "space" : s.lowercased()
                guard var events = KeySpec.events(spec, window: window) else { continue }
                if ch.isUppercase, let shifted = KeySpec.events("shift+" + spec, window: window) { events = shifted }
                for e in events { Self.dispatch(e, to: window) }
            }
            return ""
        case "type":
            guard let view = focusedSurface() else { return "error: no focused terminal" }
            // `sendText` is a paste (bracketed when the shell asks), so a newline would not run the
            // command; each `\n` becomes a real Return key press instead.
            let chunks = arg.replacingOccurrences(of: "\\t", with: "\t").components(separatedBy: "\\n")
            for (i, chunk) in chunks.enumerated() {
                if !chunk.isEmpty { view.sendText(chunk) }
                if i < chunks.count - 1, let events = KeySpec.events("return", window: view.window) {
                    for e in events { Self.dispatch(e, to: view.window) }
                }
            }
            return ""
        case "text":
            guard let view = focusedSurface() else { return "error: no focused terminal" }
            let text = view.visibleText() ?? ""
            try? text.write(to: directory.appendingPathComponent(arg), atomically: true, encoding: .utf8)
            return ""
        case "state":
            return stateProvider?() ?? "error: no state provider"
        case "click", "dclick", "rclick":
            // x y in window points, top-left origin.
            let nums = arg.split(separator: " ").compactMap { Double($0) }
            guard nums.count == 2, let window = DebugDriver.targetWindow else { return "error: click x y" }
            let p = NSPoint(x: nums[0], y: window.frame.height - nums[1])
            let clicks = command == "dclick" ? 2 : 1
            for n in 1...clicks {
                let downType: NSEvent.EventType = command == "rclick" ? .rightMouseDown : .leftMouseDown
                let upType: NSEvent.EventType = command == "rclick" ? .rightMouseUp : .leftMouseUp
                for type in [downType, upType] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: Self.nextEventNumber(), clickCount: n, pressure: 1) {
                        window.sendEvent(e)
                    }
                }
            }
            return ""
        case "drag":
            // x1 y1 x2 y2 in window points, top-left origin; ten intermediate moves.
            let nums = arg.split(separator: " ").compactMap { Double($0) }
            guard nums.count == 4, let window = DebugDriver.targetWindow else { return "error: drag x1 y1 x2 y2" }
            let h = window.frame.height
            func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: h - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let e = event(.leftMouseDown, nums[0], nums[1]) { window.sendEvent(e) }
            for i in 1...10 {
                let t = Double(i) / 10
                if let e = event(.leftMouseDragged, nums[0] + (nums[2] - nums[0]) * t, nums[1] + (nums[3] - nums[1]) * t) { window.sendEvent(e) }
                try? await Task.sleep(for: .milliseconds(16))
            }
            if let e = event(.leftMouseUp, nums[2], nums[3]) { window.sendEvent(e) }
            return ""
        case "snapshot":
            return snapshot(name: arg, in: directory)
        case "appearance":
            switch arg {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: NSApp.appearance = nil
            }
            return ""
        case "eval":
            let args = arg.split(separator: " ").map(String.init)
            guard let name = args.first, let hook = hooks[name] else { return "error: no hook \(arg)" }
            return hook(Array(args.dropFirst()))
        case "activate":
            // As when the user switches to the app: active, with its window key.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderedWindows.first { $0.windowController != nil }?.makeKeyAndOrderFront(nil)
            return ""
        case "quit":
            quitRequested = true
            return ""
        default:
            return "error: unknown command \(command)"
        }
    }

    /// Delivers a key event the way `NSApplication` does for the active app, so tests do not
    /// depend on the test app being frontmost: key equivalents go to the window's views, then the
    /// main menu; anything unclaimed becomes `keyDown`/`keyUp` on the first responder.
    static func dispatch(_ event: NSEvent, to window: NSWindow?) {
        guard let window else { return }
        // AppKit offers only ⌘ and ⌃ keys as key equivalents; a plain letter offered too would be
        // claimed by the system's Globe-key items (Emoji & Symbols is fn-E).
        if event.type == .keyDown, !event.modifierFlags.intersection([.command, .control]).isEmpty {
            if window.performKeyEquivalent(with: event) { return }
            // NSMenu resolves nil targets through the key window, which an inactive app does not
            // have; match the item here (same rule as NSMenu: the shift-applied character against
            // keyEquivalent, an uppercase letter implying ⇧) and send its action to this window.
            if let item = matchingMenuItem(for: event), let action = item.action {
                if let target = item.target ?? responder(for: action, in: window) {
                    let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
                    if enabled { NSApp.sendAction(action, to: target, from: item) }
                    return
                }
            }
        }
        window.sendEvent(event)
    }

    static func matchingMenuItem(for event: NSEvent) -> NSMenuItem? {
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let flags = event.modifierFlags.intersection(relevant)
        guard flags.contains(.command) || flags.contains(.control), let chars = event.charactersIgnoringModifiers else { return nil }
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let sub = item.submenu, let found = search(sub) { return found }
                guard !item.keyEquivalent.isEmpty else { continue }
                var mask = item.keyEquivalentModifierMask.intersection(relevant)
                if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
                if item.keyEquivalent == chars, mask == flags { return item }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }

    /// The first object in `window`'s responder chain (then the app and its delegate) that handles `action`.
    static func responder(for action: Selector, in window: NSWindow) -> AnyObject? {
        var r: NSResponder? = window.firstResponder
        while let current = r {
            if current.responds(to: action) { return current }
            r = current.nextResponder
        }
        if let d = window.delegate as? NSObject, d.responds(to: action) { return d }
        if NSApp.responds(to: action) { return NSApp }
        if let d = NSApp.delegate as? NSObject, d.responds(to: action) { return d }
        return nil
    }

    /// Real mouse events carry increasing event numbers; repeats of one number look like one event.
    private static var eventCounter = 1000
    static func nextEventNumber() -> Int {
        eventCounter += 1
        return eventCounter
    }

    /// The window commands act on: the key window, else the frontmost of PrompTTY's own windows
    /// (system panels such as the input-source indicator can be frontmost while the app is inactive).
    static var targetWindow: NSWindow? {
        // An open popover (the folder picker) takes the keys in a real run; the driven app is
        // often not active, so it may not be key. System windows (the input-source indicator) can
        // be key in our process and are never the target.
        if let popover = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) {
            return popover
        }
        if let key = NSApp.keyWindow, key.windowController != nil { return key }
        return NSApp.orderedWindows.first { $0.windowController != nil } ?? NSApp.orderedWindows.first
    }

    /// The focused pane's terminal, also when its input bar has the keys.
    func focusedSurface() -> TerminalSurfaceView? {
        let responder = Self.targetWindow?.firstResponder
        return (responder as? TerminalSurfaceView) ?? (responder as? CommandTextView)?.terminal
    }

    // MARK: Snapshots

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage` is obsoleted in the Swift SDK but still exported, and still
    /// captures the calling process's own windows without Screen Recording permission.
    private static let createImage: CreateImage? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: CreateImage.self)
    }()

    private func snapshot(name: String, in directory: URL) -> String {
        guard let createImage = Self.createImage else { return "error: CGWindowListCreateImage unavailable" }
        var lines: [String] = []
        // Child panels (the bar's completion list) are not in `orderedWindows`.
        let windows = NSApp.orderedWindows.filter(\.isVisible) + NSApp.windows.filter { $0.isVisible && $0.parent != nil }
        for (i, window) in windows.enumerated() {
            // kCGWindowListOptionIncludingWindow = 1 << 3; boundsIgnoreFraming = 1 << 0, bestResolution = 1 << 3
            guard let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else {
                lines.append("error: capture failed for window \(i)")
                continue
            }
            let url = directory.appendingPathComponent("\(name)-\(i).png")
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            lines.append("\(url.lastPathComponent) \(image.width)x\(image.height) \"\(window.title)\"")
        }
        return lines.joined(separator: "\n")
    }
}

/// Parses "ctrl+shift+d", "cmd+return", "opt+left" into key down/up events.
enum KeySpec {
    private static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "f12": 111,
    ]
    private static let specials: [String: String] = [
        "return": "\r", "tab": "\t", "space": " ", "delete": "\u{7f}", "escape": "\u{1b}",
        "left": "\u{F702}", "right": "\u{F703}", "down": "\u{F701}", "up": "\u{F700}",
    ]

    @MainActor
    static func events(_ spec: String, window: NSWindow?) -> [NSEvent]? {
        var flags: NSEvent.ModifierFlags = []
        var key: String?
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd": flags.insert(.command)
            case "ctrl": flags.insert(.control)
            case "opt", "alt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            default: key = part
            }
        }
        guard let key, let code = codes[key] else { return nil }
        if ["left", "right", "up", "down"].contains(key) { flags.insert([.numericPad, .function]) }
        if key == "f12" { flags.insert(.function) }
        // Built from CGEvents so the system translates the key code through the current keyboard
        // layout exactly as for a physical key press (characters, shifted characters, dead keys).
        var cgFlags: CGEventFlags = []
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.function) { cgFlags.insert([.maskSecondaryFn, .maskNumericPad]) }
        func make(_ down: Bool) -> NSEvent? {
            guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return nil }
            cg.flags = cgFlags
            guard let ns = NSEvent(cgEvent: cg) else { return nil }
            // Retarget to our window (CGEvent-made NSEvents carry no window number).
            return NSEvent.keyEvent(
                with: ns.type, location: .zero, modifierFlags: ns.modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0, context: nil, characters: ns.characters ?? "",
                charactersIgnoringModifiers: ns.charactersIgnoringModifiers ?? "", isARepeat: false, keyCode: code
            )
        }
        guard let down = make(true), let up = make(false) else { return nil }
        return [down, up]
    }
}
#endif
