import AppKit
import GhosttyKit

public struct GhosttyRuntimeError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Owns the single `ghostty_app_t` for the process and the six runtime callbacks.
/// Everything is main-actor; `wakeup_cb` is the only callback libghostty invokes off-main and it
/// only schedules `tick()`.
@MainActor
public final class GhosttyRuntime {
    /// IUO because `ghostty_app_new` needs a pointer to `self` as userdata, so it runs after all
    /// other stored properties are initialized.
    nonisolated(unsafe) private var appHandle: UnsafeMutableRawPointer!
    nonisolated(unsafe) private var config: UnsafeMutableRawPointer

    var app: UnsafeMutableRawPointer { appHandle }

    public weak var sink: GhosttyActionSink?
    public private(set) var configDiagnostics: [String] = []
    /// Called after every reload with the current diagnostics (possibly empty).
    public var onConfigDiagnostics: (([String]) -> Void)?
    /// Called when `ghostty_surface_new` fails for a view.
    public var onSurfaceCreationFailed: ((TerminalSurfaceView) -> Void)?

    /// The only config file libghostty reads. `~/.config/ghostty` is never consulted.
    public let configURL: URL

    public init(configURL: URL) throws {
        self.configURL = configURL
        try GhosttyLibrary.initialize()
        let (cfg, diags) = GhosttyConfigFile.load(configURL)
        config = cfg
        configDiagnostics = diags

        var rc = ghostty_runtime_config_s()
        rc.userdata = Unmanaged.passUnretained(self).toOpaque()
        rc.supports_selection_clipboard = false
        rc.wakeup_cb = ghosttyWakeup
        rc.action_cb = ghosttyAction
        rc.read_clipboard_cb = ghosttyReadClipboard
        rc.confirm_read_clipboard_cb = ghosttyConfirmReadClipboard
        rc.write_clipboard_cb = ghosttyWriteClipboard
        rc.close_surface_cb = ghosttyCloseSurface

        guard let created = ghostty_app_new(&rc, cfg) else {
            // All stored properties are initialized, so deinit runs and frees `config`.
            throw GhosttyRuntimeError(message: "ghostty_app_new failed")
        }
        appHandle = created
    }

    deinit {
        if let appHandle { ghostty_app_free(appHandle) }
        ghostty_config_free(config)
    }

    // MARK: Public API

    public func tick() { ghostty_app_tick(app) }

    /// Re-reads `configURL` and applies it to every surface.
    public func reloadConfig() {
        let (cfg, diags) = GhosttyConfigFile.load(configURL)
        // Order matters. Store `cfg` *before* updating: `ghostty_app_update_config` ends by
        // emitting an app-level CONFIG_CHANGE carrying the conditional-state-applied config
        // (e.g. the light/dark `theme` variant), and `dispatch` replaces `config` with a clone of
        // it, freeing `cfg`. Storing afterwards would discard that clone and keep the raw `cfg`.
        // `cfg` must not be touched after the update call (it may already be freed); if the
        // update fails before the app-level action, `config` stays `cfg` and we still own it.
        ghostty_config_free(config)
        config = cfg
        ghostty_app_update_config(app, cfg)
        configDiagnostics = diags
        onConfigDiagnostics?(diags)
    }

    public func setFocus(_ focused: Bool) { ghostty_app_set_focus(app, focused) }

    public var needsConfirmQuit: Bool { ghostty_app_needs_confirm_quit(app) }

    public func setColorScheme(dark: Bool) {
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    /// The `background` color of the current config, or nil if libghostty cannot report it.
    public var configuredBackground: (red: UInt8, green: UInt8, blue: UInt8)? {
        var color = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return nil }
        return (color.r, color.g, color.b)
    }

    /// The `foreground` color of the current config.
    public var configuredForeground: (red: UInt8, green: UInt8, blue: UInt8)? {
        var color = ghostty_config_color_s()
        let key = "foreground"
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return nil }
        return (color.r, color.g, color.b)
    }

    /// The first 16 palette colors (the ANSI ones) of the current config.
    public var configuredANSIPalette: [(red: UInt8, green: UInt8, blue: UInt8)]? {
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &palette, key, UInt(key.utf8.count)) else { return nil }
        return withUnsafeBytes(of: palette.colors) { raw in
            raw.bindMemory(to: ghostty_config_color_s.self).prefix(16).map { ($0.r, $0.g, $0.b) }
        }
    }

    // MARK: Internal

    func surfaceCreationFailed(_ view: TerminalSurfaceView) {
        onSurfaceCreationFailed?(view)
    }

    /// Entry point from `action_cb`. Returns whether the action was performed.
    func dispatch(target cTarget: ghostty_target_s, action cAction: ghostty_action_s) -> Bool {
        if cAction.tag == GHOSTTY_ACTION_CONFIG_CHANGE, cTarget.tag == GHOSTTY_TARGET_APP,
           let newConfig = cAction.action.config_change.config {
            // libghostty keeps ownership of the passed config; clone to keep our own copy current.
            // App target only: surface-level CONFIG_CHANGE fires while `ghostty_app_update_config`
            // is still iterating surfaces with the caller's config (which `config` may be, see
            // `reloadConfig`), so freeing `config` there would be a use-after-free; it also
            // carries per-surface conditional state, not the app's.
            if let clone = ghostty_config_clone(newConfig) {
                ghostty_config_free(config)
                config = clone
            }
        }

        let action = GhosttyAction(cAction)
        guard action.isImplemented else { return false }

        let target: GhosttyActionTarget
        switch cTarget.tag {
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = cTarget.target.surface, let ud = ghostty_surface_userdata(surface) else { return false }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
            switch action {
            case .initialSize(let w, let h): view.noteInitialSize(CGSize(width: Double(w), height: Double(h)))
            case .cellSize(let w, let h): view.noteCellSize(CGSize(width: Double(w), height: Double(h)))
            case .showChildExited: view.markExited()
            case .mouseShape(let shape): view.apply(mouseShape: shape)
            case .mouseVisibility(let visible): if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
            default: break
            }
            target = .surface(view)
        default:
            target = .app
        }

        switch action {
        case .reloadConfig:
            reloadConfig()
            return true
        case .openConfig:
            // There is no Ghostty config file to open; PrompTTY's settings live in its Settings window.
            return false
        case .mouseShape, .mouseVisibility:
            return true
        default:
            return sink?.handle(action, target: target) ?? false
        }
    }
}

// MARK: - C callbacks
// These must be plain functions (no captures) so they convert to @convention(c) pointers.

/// Called from any thread. Only schedules a tick. The runtime is resolved strongly here and held
/// through the hop so the queued block never dereferences a raw pointer.
private func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            runtime.tick()
        }
    }
}

/// Called on the main thread during `ghostty_app_tick` or synchronously inside `ghostty_surface_new`.
private func ghosttyAction(_ app: UnsafeMutableRawPointer?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    // Raw pointers are not Sendable; we are already on main, so rebinding `app` as
    // nonisolated(unsafe) lets the assumeIsolated closure capture it.
    nonisolated(unsafe) let app = app
    return MainActor.assumeIsolated {
        guard let app, let ud = ghostty_app_userdata(app) else { return false }
        return Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue().dispatch(target: target, action: action)
    }
}

/// `userdata` here is the *surface's* userdata (our view), not the app's.
private func ghosttyReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool {
    nonisolated(unsafe) let userdata = userdata
    nonisolated(unsafe) let state = state
    return MainActor.assumeIsolated {
        guard let userdata, location == GHOSTTY_CLIPBOARD_STANDARD else { return false }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        view.completeClipboardRequest(text, state: state, confirmed: false)
        return true
    }
}

/// MVP policy (no prompt UI yet): OSC 52 *reads* are denied, matching Ghostty's
/// `clipboard-read = ask` default by refusing in the absence of a prompt. The denial is an empty
/// reply with `confirmed: true`; replying `confirmed: false` makes libghostty re-ask
/// synchronously, which recurses forever. Pastes and OSC 52 writes that need confirmation are
/// approved.
private func ghosttyConfirmReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ string: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e) {
    // Copy the C string before hopping; libghostty only guarantees it for the callback's duration.
    let text = string.map { String(cString: $0) } ?? ""
    nonisolated(unsafe) let userdata = userdata
    nonisolated(unsafe) let state = state
    MainActor.assumeIsolated {
        guard let userdata else { return }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        if request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ {
            // Deny without a prompt: an empty confirmed reply makes libghostty answer the
            // program with an empty OSC 52 payload and destroys the request state.
            view.completeClipboardRequest("", state: state, confirmed: true)
            return
        }
        view.completeClipboardRequest(text, state: state, confirmed: true)
    }
}

private func ghosttyWriteClipboard(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ contents: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int, _ confirm: Bool) {
    guard location == GHOSTTY_CLIPBOARD_STANDARD, let contents, count > 0 else { return }
    // The user's config asked for confirmation and there is no prompt UI yet: refuse rather than
    // write silently.
    guard !confirm else { return }
    // Copy the text out of the C buffer first; only the resulting String crosses into the main actor.
    var text: String?
    for i in 0..<count {
        let item = contents[i]
        guard let mime = item.mime, let data = item.data else { continue }
        if String(cString: mime) == "text/plain" {
            text = String(cString: data)
            break
        }
    }
    guard let text else { return }
    MainActor.assumeIsolated {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// Always invoked on the main thread (and never from inside `ghostty_surface_free`). The view is
/// resolved into a strong reference immediately, then the model is touched on the next run-loop
/// turn so a synchronous call from inside our own close path cannot re-enter it. The strong
/// capture keeps the view alive even if the tab-close path releases it in the current turn.
private func ghosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    guard let userdata else { return }
    nonisolated(unsafe) let ud = userdata
    MainActor.assumeIsolated {
        // TerminalSurfaceView is @MainActor, hence Sendable: the block can hold it strongly.
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard !view.isTornDown else { return }
                _ = view.runtime.sink?.handle(.closeSurface(processAlive: processAlive), target: .surface(view))
            }
        }
    }
}
