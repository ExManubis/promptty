#if os(iOS)
import Foundation
import os
import UIKit
import GhosttyKit

public struct MirrorEngineError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// The iPhone's libghostty: the process's one `ghostty_app_t`, its config and the runtime
/// callbacks. Its surfaces (`MirrorSurfaceView`) start no program: they show what a pane on the
/// Mac writes and send back what is typed on the phone (Engine patch 0006, termio's host backend).
/// Main-actor; `wakeup_cb` is the only callback libghostty invokes off-main and it only schedules
/// `tick()`.
@MainActor
public final class MirrorEngine {
    /// IUO because `ghostty_app_new` needs a pointer to `self` as userdata, so it runs after all
    /// other stored properties are initialized.
    nonisolated(unsafe) private var appHandle: UnsafeMutableRawPointer!
    nonisolated(unsafe) private var config: UnsafeMutableRawPointer

    var app: UnsafeMutableRawPointer { appHandle }

    /// Whether a tick is already queued on the main queue. Set from any thread by `wakeup_cb`.
    nonisolated let tickPending = OSAllocatedUnfairLock(initialState: false)

    /// libghostty's complaints about the config, if any.
    public let configDiagnostics: [String]

    /// `configText` is a Ghostty config file's contents, as the Mac writes `terminal.conf`
    /// (`TerminalConfigWriter`), so the phone draws with the Mac's font and theme. The phone has no
    /// theme files: a theme comes inline (its palette, background and foreground lines), not by name.
    public init(configText: String) throws {
        try MirrorLibrary.initialize()
        let (cfg, diags) = try MirrorLibrary.loadConfig(Self.phoneConfig(configText))
        config = cfg
        configDiagnostics = diags

        var rc = ghostty_runtime_config_s()
        rc.userdata = Unmanaged.passUnretained(self).toOpaque()
        rc.supports_selection_clipboard = false
        rc.wakeup_cb = mirrorWakeup
        rc.action_cb = mirrorAction
        rc.read_clipboard_cb = mirrorReadClipboard
        rc.confirm_read_clipboard_cb = mirrorConfirmReadClipboard
        rc.write_clipboard_cb = mirrorWriteClipboard
        rc.close_surface_cb = mirrorCloseSurface

        guard let created = ghostty_app_new(&rc, cfg) else {
            throw MirrorEngineError(message: "ghostty_app_new failed")
        }
        appHandle = created
        ghostty_app_set_color_scheme(created, GHOSTTY_COLOR_SCHEME_DARK)
    }

    deinit {
        if let appHandle { ghostty_app_free(appHandle) }
        ghostty_config_free(config)
    }

    /// SF Mono, the Mac's default font, is on iOS only as the system's monospaced font, which
    /// CoreText finds by this family name and not by "SF Mono" (that falls back to libghostty's
    /// built-in JetBrains Mono).
    static let systemMonospacedFamily = ".AppleSystemUIFontMonospaced"

    static func phoneConfig(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.replacingOccurrences(of: " ", with: "") == "font-family=SFMono"
                ? "font-family = \(systemMonospacedFamily)" : String(line)
        }.joined(separator: "\n")
    }

    func tick() {
        ghostty_app_tick(app)
    }

    /// The config's background, for whatever is drawn around the terminal.
    public var background: UIColor? {
        var color = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return nil }
        return UIColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }
}

/// Process-wide libghostty setup, exactly once.
enum MirrorLibrary {
    private static let initialization: Result<Void, MirrorEngineError> = {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
            return .failure(MirrorEngineError(message: "ghostty_init failed"))
        }
        return .success(())
    }()

    static func initialize() throws {
        try initialization.get()
    }

    /// A finalized config from `text`; the caller owns and frees it. libghostty reads config only
    /// from files, so the text goes through one in the temporary folder.
    static func loadConfig(_ text: String) throws -> (UnsafeMutableRawPointer, [String]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-\(UUID().uuidString).conf")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cfg = ghostty_config_new()!
        url.path.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_finalize(cfg)
        let diags = (0..<ghostty_config_diagnostics_count(cfg)).compactMap { i in
            ghostty_config_get_diagnostic(cfg, i).message.map { String(cString: $0) }
        }
        return (cfg, diags)
    }
}

// MARK: - C callbacks
// Plain functions (no captures) so they convert to @convention(c) pointers.

/// Called from any thread. Only schedules a tick; one queued tick serves any number of wakeups.
private func mirrorWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let engine = Unmanaged<MirrorEngine>.fromOpaque(userdata).takeUnretainedValue()
    guard engine.tickPending.withLock({ pending in
        defer { pending = true }
        return !pending
    }) else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            engine.tickPending.withLock { $0 = false }
            engine.tick()
        }
    }
}

/// Called on the main thread. The phone acts on none yet: the Mac owns the pane's title, bells
/// and the rest, and tells the phone itself.
private func mirrorAction(_ app: UnsafeMutableRawPointer?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    false
}

/// A paste comes from `MirrorSurfaceView.paste(_:)`; a program reading the clipboard (OSC 52) is
/// not served.
private func mirrorReadClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?,
    _ mimes: UnsafePointer<UnsafePointer<CChar>?>?, _ mimesCount: Int, _ list: Bool
) -> ghostty_clipboard_read_result_e {
    GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
}

private func mirrorConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e
) {}

/// A copy (or a program's OSC 52 write that needs no confirmation) goes to the pasteboard.
private func mirrorWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e,
    _ contents: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int, _ confirm: Bool
) {
    guard location == GHOSTTY_CLIPBOARD_STANDARD, !confirm, let contents else { return }
    var text: String?
    for i in 0..<count {
        let item = contents[i]
        guard let mime = item.mime, let data = item.data, String(cString: mime).hasPrefix("text/plain") else { continue }
        text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
        break
    }
    guard let text else { return }
    MainActor.assumeIsolated { UIPasteboard.general.string = text }
}

/// A mirrored pane closes when the Mac closes it, never from the phone's side.
private func mirrorCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {}
#endif
