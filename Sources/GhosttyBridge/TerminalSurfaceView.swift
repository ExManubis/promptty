import AppKit
import GhosttyKit
import QuartzCore

public struct TerminalSurfaceConfiguration: Sendable {
    public var workingDirectory: String?
    public init(workingDirectory: String? = nil) {
        self.workingDirectory = workingDirectory
    }
}

/// Hosts one libghostty surface in a Metal layer. Input handling lives in TerminalSurfaceView+Input.swift.
@MainActor
public final class TerminalSurfaceView: NSView {
    /// Opaque handle the app uses to find the owning tab. The bridge never reads it.
    public var token: AnyHashable?

    /// Size libghostty asked for during `ghostty_surface_new`, before this view had a window.
    public private(set) var pendingInitialSize: CGSize?
    public private(set) var cellSize: CGSize = .zero
    public private(set) var hasExited = false

    let runtime: GhosttyRuntime
    private let configuration: TerminalSurfaceConfiguration

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
        ]
        sizeDidChange()
        updateOcclusion()
        focusDidChange()
    }

    private func createSurfaceIfNeeded() {
        guard surface == nil, !isFreed else { return }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB
        let created: UnsafeMutableRawPointer? = withOptionalCString(configuration.workingDirectory) { dir in
            cfg.working_directory = dir
            return ghostty_surface_new(runtime.app, &cfg)
        }
        surface = created
        if created == nil {
            runtime.surfaceCreationFailed(self)
        }
    }

    /// Frees the surface exactly once. Safe to call from both the tab-close path and `close_surface_cb`.
    public func teardown() {
        guard let surface, !isFreed else { return }
        isFreed = true
        ghostty_surface_free(surface)
        self.surface = nil
    }

    public func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    public var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    public func markExited() { hasExited = true }

    // MARK: Geometry

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let window else { return }
        let scale = Double(window.backingScaleFactor)
        ghostty_surface_set_content_scale(surface, scale, scale)
        sizeDidChange()
    }

    private func sizeDidChange() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let w = UInt32(max(1, bounds.width * scale))
        let h = UInt32(max(1, bounds.height * scale))
        ghostty_surface_set_size(surface, w, h)
    }

    // MARK: Focus and visibility

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        focusDidChange()
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        focusDidChange()
        return ok
    }

    private func focusDidChange() {
        guard let surface else { return }
        let focused = (window?.isKeyWindow ?? false) && window?.firstResponder === self
        ghostty_surface_set_focus(surface, focused)
    }

    public override func viewDidHide() { super.viewDidHide(); updateOcclusion() }
    public override func viewDidUnhide() { super.viewDidUnhide(); updateOcclusion() }

    private var explicitlyOccluded = false

    /// Containers call this for tabs that are not selected so hidden surfaces stop rendering.
    public func setOccluded(_ occluded: Bool) {
        explicitlyOccluded = occluded
        updateOcclusion()
    }

    private func updateOcclusion() {
        guard let surface else { return }
        let windowVisible = window?.occlusionState.contains(.visible) ?? false
        let visible = windowVisible && !isHiddenOrHasHiddenAncestor && !explicitlyOccluded
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

extension TerminalSurfaceView {
    public func apply(mouseShape: MouseShape) {
        currentMouseShape = mouseShape
        window?.invalidateCursorRects(for: self)
    }
}
