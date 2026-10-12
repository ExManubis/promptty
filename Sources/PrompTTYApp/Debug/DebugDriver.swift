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
            let ok = NSApp.sendAction(NSSelectorFromString(arg), to: nil, from: nil)
            return ok ? "" : "error: no target for \(arg)"
        case "key":
            guard let events = KeySpec.events(arg, window: NSApp.keyWindow ?? NSApp.orderedWindows.first) else { return "error: bad key \(arg)" }
            for e in events { NSApp.sendEvent(e) }
            return ""
        case "type":
            guard let view = focusedSurface() else { return "error: no focused terminal" }
            // `sendText` is a paste (bracketed when the shell asks), so a newline would not run the
            // command; each `\n` becomes a real Return key press instead.
            let chunks = arg.replacingOccurrences(of: "\\t", with: "\t").components(separatedBy: "\\n")
            for (i, chunk) in chunks.enumerated() {
                if !chunk.isEmpty { view.sendText(chunk) }
                if i < chunks.count - 1, let events = KeySpec.events("return", window: view.window) {
                    for e in events { NSApp.sendEvent(e) }
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
        case "quit":
            quitRequested = true
            return ""
        default:
            return "error: unknown command \(command)"
        }
    }

    func focusedSurface() -> TerminalSurfaceView? {
        (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first)?.firstResponder as? TerminalSurfaceView
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
        let windows = NSApp.orderedWindows.filter(\.isVisible)
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
        "left": 123, "right": 124, "down": 125, "up": 126,
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
        let base = specials[key] ?? key
        var chars = flags.contains(.shift) ? base.uppercased() : base
        if flags.contains(.control), key.count == 1, let scalar = key.unicodeScalars.first, scalar.isASCII, scalar.properties.isAlphabetic {
            chars = String(UnicodeScalar(UInt8(scalar.value & 0x1f)))
        }
        if ["left", "right", "up", "down"].contains(key) { flags.insert([.numericPad, .function]) }
        func make(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars,
                charactersIgnoringModifiers: base, isARepeat: false, keyCode: code
            )
        }
        guard let down = make(.keyDown), let up = make(.keyUp) else { return nil }
        return [down, up]
    }
}
#endif
