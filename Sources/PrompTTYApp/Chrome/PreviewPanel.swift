import AppKit
import SwiftUI

/// The window a tab preview shows in: beside the sidebar, above the window, and never key or
/// clickable, so the terminal and the bar keep the keys while it shows.
@MainActor
final class PreviewPanel {
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?

    /// Shows `content` to the right of `row` (in the window's top-left coordinates).
    func show(_ content: some View, beside row: CGRect, in window: NSWindow) {
        let view = AnyView(content)
        let panel = self.panel ?? make()
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = [.intrinsicContentSize]
            panel.contentView = hosting
            self.hosting = hosting
        }
        let size = hosting?.fittingSize ?? .zero
        // Row coordinates are from the window's top-left; the screen's origin is bottom-left.
        let frame = window.frame
        var origin = NSPoint(x: frame.minX + row.maxX + 10, y: frame.maxY - row.midY - size.height / 2)
        if let screen = window.screen?.visibleFrame {
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
            origin.x = min(origin.x, screen.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible == true }

    private func make() -> NSPanel {
        let panel = NonKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        self.panel = panel
        return panel
    }
}

private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
