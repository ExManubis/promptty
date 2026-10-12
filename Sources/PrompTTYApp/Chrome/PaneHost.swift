import AppKit
import GhosttyBridge
import SwiftUI

/// Places a pane's long-lived `TerminalSurfaceView` in the SwiftUI tree. SwiftUI may create and
/// destroy hosts freely (and during a layout change can briefly have two hosts for one pane);
/// the surface (and its shell) lives in the window controller and is only moved between hosts,
/// never recreated.
struct PaneHost: NSViewRepresentable {
    let surface: TerminalSurfaceView
    let visible: Bool

    func makeNSView(context: Context) -> PaneHostView { PaneHostView() }

    func updateNSView(_ host: PaneHostView, context: Context) {
        host.host(surface)
        host.isHidden = !visible
        surface.setOccluded(!visible)
    }

    static func dismantleNSView(_ host: PaneHostView, coordinator: ()) {
        host.dismantle()
    }
}

/// Rounded, clipping container for one surface. Clipping happens here, in AppKit, because the
/// surface renders into a `CAMetalLayer` that SwiftUI's clip shapes do not reliably mask.
///
/// Hosts that are in a window register per surface. When the host holding a surface leaves the
/// window (SwiftUI discarding a transient copy, or the old position after a move), it hands the
/// surface to another live host for the same surface instead of taking it out of the window.
final class PaneHostView: NSView {
    private(set) var surface: TerminalSurfaceView?

    private struct WeakHost { weak var host: PaneHostView? }
    @MainActor private static var live: [ObjectIdentifier: [WeakHost]] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.paneCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    func host(_ new: TerminalSurfaceView) {
        if surface !== new {
            leave()
            surface = new
        }
        if window != nil { join() }
    }

    func dismantle() {
        leave()
        surface = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { join() }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { leave() }
    }

    override func layout() {
        super.layout()
        for sub in subviews { sub.frame = bounds }
    }

    // MARK: Registry

    /// Registers as a live host and takes the surface.
    private func join() {
        guard let surface else { return }
        let key = ObjectIdentifier(surface)
        var hosts = Self.live[key, default: []].filter { $0.host != nil && $0.host !== self }
        hosts.append(WeakHost(host: self))
        Self.live[key] = hosts
        adopt()
    }

    /// Unregisters; if this host holds the surface, passes it to another live host.
    private func leave() {
        guard let surface else { return }
        let key = ObjectIdentifier(surface)
        let others = Self.live[key, default: []].compactMap(\.host).filter { $0 !== self }
        Self.live[key] = others.isEmpty ? nil : others.map { WeakHost(host: $0) }
        guard surface.superview === self else { return }
        if let next = others.last(where: { $0.window != nil }) {
            next.adopt()
        }
    }

    private func adopt() {
        guard let surface, surface.superview !== self else { return }
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
    }
}
