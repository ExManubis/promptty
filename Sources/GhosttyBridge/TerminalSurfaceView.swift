import AppKit
import GhosttyKit
import QuartzCore

public struct TerminalSurfaceConfiguration: Sendable {
    public var workingDirectory: String?
    /// A split's source pane: the new surface inherits its settings (e.g. a zoomed font size).
    public var inheritFrom: TerminalSurfaceView?
    /// Added to the shell's environment.
    public var environment: [String: String]
    /// Typed into the terminal as it starts (a command and its Return), for shells that cannot
    /// tell when they are ready.
    public var initialInput: String?
    public init(workingDirectory: String? = nil, inheritFrom: TerminalSurfaceView? = nil, environment: [String: String] = [:], initialInput: String? = nil) {
        self.workingDirectory = workingDirectory
        self.inheritFrom = inheritFrom
        self.environment = environment
        self.initialInput = initialInput
    }
}

/// Hosts one libghostty surface in a Metal layer. Input handling lives in TerminalSurfaceView+Input.swift.
@MainActor
public final class TerminalSurfaceView: NSView {
    /// Opaque handle the app uses to find the owning pane. The bridge never reads it.
    public var token: AnyHashable?
    /// Called when the view becomes first responder (a click or programmatic focus).
    public var onFocus: (() -> Void)?
    /// Called each time the view joins a window. Hosts that move the view between containers use
    /// it to restore focus, which AppKit drops when a first responder leaves the window.
    public var onAttachedToWindow: (() -> Void)?
    /// Called after the terminal grid was given a new size.
    public var onSizeChange: (() -> Void)?
    /// Asked before the terminal takes a key: a responder returned here gets focus and the key
    /// instead (the input bar while the shell is at a prompt). ⌘ keys still go to the menus.
    public var keyRedirect: (() -> NSResponder?)?
    /// Files dropped on the terminal. Returns false to decline the drop.
    public var onFileDrop: (([URL]) -> Bool)?
    /// Drawn over the terminal by whatever hosts it, and moved with it. The terminal is a
    /// layer-hosting view (libghostty owns its layer), so it cannot have subviews of its own.
    public var overlay: NSView?
    /// The pointer moved over the terminal (the event), or left it (nil).
    public var onPointerMoved: ((NSEvent?) -> Void)?
    /// The screen scrolled, the scrollback grew, or the cells changed size: whatever is drawn over
    /// the terminal in step with its rows has moved. Reaching the overlay directly saves the
    /// app looking this surface's pane up on every one of these (thousands a second in a stream).
    public var onLayoutChange: (() -> Void)?

    /// The pointer is over a link in the output (its text), or left it (nil). Arrives with every
    /// mouse move over text, so it goes straight to whoever shows it.
    public var onLinkHover: ((String?) -> Void)?

    /// Size libghostty asked for during `ghostty_surface_new`, before this view had a window.
    public private(set) var pendingInitialSize: CGSize?
    public private(set) var cellSize: CGSize = .zero
    public private(set) var hasExited = false

    let runtime: GhosttyRuntime
    private var configuration: TerminalSurfaceConfiguration

    // Plain raw pointer: `ghostty_surface_t` is already an optional typealias (see Task 5 Step 3 note).
    nonisolated(unsafe) private(set) var surface: UnsafeMutableRawPointer?
    nonisolated(unsafe) private var isFreed = false

    // Input state shared with the +Input extension.
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    var currentMouseShape: MouseShape = .default
    var trackingArea: NSTrackingArea?

    // Read from `deinit`, which is nonisolated, hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

    public init(runtime: GhosttyRuntime, configuration: TerminalSurfaceConfiguration) {
        self.runtime = runtime
        self.configuration = configuration
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        registerForDraggedTypes([.fileURL])
    }

    // MARK: File drops

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(in: sender).isEmpty || onFileDrop == nil ? [] : .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(in: sender)
        guard !urls.isEmpty, let onFileDrop else { return false }
        return onFileDrop(urls)
    }

    static func fileURLs(in sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let surface, !isFreed {
            ghostty_surface_free(surface)
        }
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Windows use `isMovableByWindowBackground`; a drag in the terminal selects text instead.
    public override var mouseDownCanMoveWindow: Bool { false }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.displaySyncEnabled = true
        layer.framebufferOnly = true
        return layer
    }

    // MARK: Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
        windowObservers.removeAll()
        guard let window else { return }
        createSurfaceIfNeeded()
        let nc = NotificationCenter.default
        windowObservers = [
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusDidChange() }
            },
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusDidChange() }
            },
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateOcclusion() }
            },
            nc.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDisplay() }
            },
        ]
        sizeDidChange()
        updateDisplay()
        updateOcclusion()
        focusDidChange()
        onAttachedToWindow?()
    }

    private func createSurfaceIfNeeded() {
        guard surface == nil, !isFreed else { return }
        var cfg: ghostty_surface_config_s
        if let source = configuration.inheritFrom?.surface {
            cfg = ghostty_surface_inherited_config(source, GHOSTTY_SURFACE_CONTEXT_SPLIT)
            cfg.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
        } else {
            cfg = ghostty_surface_config_new()
            cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB
        }
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        let inheritedDirectory = cfg.working_directory
        // The source is only needed for creation; do not keep it alive.
        configuration.inheritFrom = nil
        // The C strings must outlive `ghostty_surface_new`, which copies them.
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        defer { cStrings.forEach { free($0) } }
        var envVars: [ghostty_env_var_s] = configuration.environment.sorted { $0.key < $1.key }.map { key, value in
            let k = strdup(key)!, v = strdup(value)!
            cStrings += [k, v]
            return ghostty_env_var_s(key: k, value: v)
        }
        let created: UnsafeMutableRawPointer? = envVars.withUnsafeMutableBufferPointer { vars in
            cfg.env_vars = vars.baseAddress
            cfg.env_var_count = vars.count
            return withOptionalCString(configuration.workingDirectory) { dir in
                cfg.working_directory = dir ?? inheritedDirectory
                return withOptionalCString(configuration.initialInput) { input in
                    cfg.initial_input = input
                    return ghostty_surface_new(runtime.app, &cfg)
                }
            }
        }
        surface = created
        if created != nil { updateColorScheme() }
        if created == nil {
            // Do not retry on later window moves (and re-fire the failure callback).
            isFreed = true
            runtime.surfaceCreationFailed(self)
        }
    }

    /// Frees the surface exactly once. Safe to call from both the tab-close path and `close_surface_cb`.
    public func teardown() {
        guard let handle = surface, !isFreed else { return }
        // Clear state first so nothing re-entering during the free sees a live handle.
        surface = nil
        isFreed = true
        ghostty_surface_free(handle)
    }

    /// True once the surface has been freed (or failed to be created).
    public var isTornDown: Bool { isFreed }

    public func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    public var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    public func markExited() { hasExited = true }

    /// Runs a libghostty binding action such as `copy_to_clipboard` or `increase_font_size:1`.
    /// PrompTTY binds no keys in libghostty, so menu commands reach terminal actions this way.
    @discardableResult
    public func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
    }

    /// The process that owns the terminal now (the shell at a prompt, a program while it runs).
    public var foregroundPID: Int? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        return pid > 0 ? Int(pid) : nil
    }

    public var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    // Standard Edit menu actions. libghostty binds no keys, so ⌘C/⌘V/⌘A arrive here from the menu.
    @objc public func copy(_ sender: Any?) { performBindingAction("copy_to_clipboard") }
    @objc public func paste(_ sender: Any?) {
        // At a prompt a paste belongs in the input bar, not in the shell's hidden line.
        if let target = keyRedirect?(), let window {
            window.makeFirstResponder(target)
            NSApp.sendAction(#selector(NSText.paste(_:)), to: target, from: sender)
            return
        }
        performBindingAction("paste_from_clipboard")
    }
    @objc public override func selectAll(_ sender: Any?) { performBindingAction("select_all") }

    // MARK: Appearance

    /// Conditional config (`theme = light:…,dark:…`) is resolved per surface, so each surface has
    /// to be told when the *system* appearance flips. The app calls this; the view's own
    /// appearance is not used because windows set theirs from the tint, which would feed back.
    public func setColorScheme(dark: Bool) {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    private func updateColorScheme() {
        setColorScheme(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    // MARK: Geometry

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange()
    }

    /// The content scale last sent. A view drawn through a SwiftUI scale effect is told its backing
    /// properties changed on every animation frame, even though the screen's scale did not.
    private var sentScale: CGFloat?

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let window, window.backingScaleFactor != sentScale else { return }
        sentScale = window.backingScaleFactor
        // libghostty's layer is not told the new scale by AppKit; without this a window moved
        // from a Retina to a 1x screen draws four times the pixels, and the other way is blurry.
        // As upstream Ghostty does, without an implicit animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        let scale = Double(window.backingScaleFactor)
        ghostty_surface_set_content_scale(surface, scale, scale)
        sizeDidChange(force: true)
    }

    #if DEBUG
    /// Pixel sizes sent to libghostty, for the debug driver's one-resize-per-layout-change check.
    nonisolated(unsafe) public static var sentSizes: [String] = []
    #endif

    /// The last pixel size sent; AppKit re-sets an unchanged frame often (SwiftUI does on every
    /// animation frame), and each set would otherwise reach libghostty as a resize.
    private var sentSize: (width: UInt32, height: UInt32)?
    /// When the terminal last got a new size, or a key: programs redraw for either, which is not
    /// activity of their own.
    public private(set) var lastResize: Date?
    public internal(set) var lastKeyPress: Date?

    /// How the terminal follows this view's size.
    public enum ResizeMode: Sendable {
        /// Every new size goes to the terminal at once.
        case live
        /// At most one new size per `ResizeThrottle.interval`, and the latest one always arrives
        /// (a split divider being dragged).
        case throttled
        /// The terminal keeps its size, drawn from the view's top-left corner, and gets the view's
        /// size when this ends (the sidebar sliding: one resize instead of one per frame).
        case held
    }

    public var resizeMode: ResizeMode = .live {
        didSet {
            guard resizeMode != oldValue else { return }
            trailingResize?.cancel()
            trailingResize = nil
            sizeDidChange()
        }
    }

    private var throttle = ResizeThrottle()
    /// The size skipped while throttled, sent once the interval is up.
    private var trailingResize: Task<Void, Never>?

    private func sizeDidChange(force: Bool = false) {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let w = UInt32(max(1, (bounds.width * scale).rounded()))
        let h = UInt32(max(1, (bounds.height * scale).rounded()))
        if !force, let sent = sentSize, sent.width == w, sent.height == h { return }
        let now = CACurrentMediaTime()
        if !force {
            switch resizeMode {
            case .live: break
            case .held: return
            case .throttled:
                let wait = throttle.wait(at: now)
                guard wait > 0 else { break }
                if trailingResize == nil {
                    trailingResize = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(wait))
                        guard !Task.isCancelled, let self else { return }
                        self.trailingResize = nil
                        self.sizeDidChange()
                    }
                }
                return
            }
        }
        throttle.noteSent(at: now)
        sentSize = (w, h)
        lastResize = Date()
        #if DEBUG
        Self.sentSizes.append("\(w)x\(h)")
        #endif
        ghostty_surface_set_size(surface, w, h)
        onSizeChange?()
    }

    // MARK: Focus and visibility

    // AppKit has not updated `window.firstResponder` yet inside these overrides, so pass the
    // new focus state explicitly instead of deriving it.
    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let surface {
            ghostty_surface_set_focus(surface, ok && (window?.isKeyWindow ?? false))
        }
        if ok { onFocus?() }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return ok
    }

    /// For window key/resign notifications, where `firstResponder` is already settled.
    private func focusDidChange() {
        guard let surface else { return }
        let focused = (window?.isKeyWindow ?? false) && window?.firstResponder === self
        ghostty_surface_set_focus(surface, focused)
    }

    /// The display the window is on, for the renderer's display link. A focused surface draws
    /// only when that link fires (vsync); one never told its display draws far too rarely: a
    /// program redrawing many times a second (Claude Code) showed a few frames a second, in bursts.
    private func updateDisplay() {
        guard let surface, let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        ghostty_surface_set_display_id(surface, number.uint32Value)
    }

    public override func viewDidHide() { super.viewDidHide(); updateOcclusion() }
    public override func viewDidUnhide() { super.viewDidUnhide(); updateOcclusion() }

    private var explicitlyOccluded = false

    /// Containers call this for tabs that are not selected so hidden surfaces stop rendering.
    public func setOccluded(_ occluded: Bool) {
        explicitlyOccluded = occluded
        updateOcclusion()
    }

    /// The visibility last sent: every call wakes the renderer, and these are called often.
    private var sentVisible: Bool?

    private func updateOcclusion() {
        guard let surface else { return }
        let windowVisible = window?.occlusionState.contains(.visible) ?? false
        let visible = windowVisible && !isHiddenOrHasHiddenAncestor && !explicitlyOccluded
        guard visible != sentVisible else { return }
        sentVisible = visible
        ghostty_surface_set_occlusion(surface, visible)
    }

    // MARK: Runtime hooks (internal)

    func noteInitialSize(_ size: CGSize) { pendingInitialSize = size }
    func noteCellSize(_ size: CGSize) { cellSize = size }

    func completeClipboardRequest(_ string: String, state: UnsafeMutableRawPointer?, confirmed: Bool) {
        guard let surface else { return }
        string.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
        }
    }
}

func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString { body($0) }
}
