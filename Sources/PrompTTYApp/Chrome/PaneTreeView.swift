import SwiftUI
import WorkspaceModel

/// Lays out one tab's split tree: each leaf a `PaneCard`, each split two subtrees with a
/// draggable gap between them.
struct PaneTreeView: View {
    let node: SplitNode
    let path: SplitPath
    let tab: WorkspaceModel.Tab
    let visible: Bool
    let chrome: WindowChromeModel
    let actions: ChromeActions

    var body: some View {
        switch node {
        case .leaf(let id):
            if let pane = tab.pane(id) {
                PaneCard(pane: pane, tab: tab, visible: visible, chrome: chrome, actions: actions)
                    .id(id)
            }
        case .split(let axis, let ratio, let first, let second):
            GeometryReader { geo in
                let total = axis == .horizontal ? geo.size.width : geo.size.height
                let available = max(0, total - ChromeMetrics.paneGap)
                let firstLength = (available * ratio).rounded()
                let layout = axis == .horizontal
                    ? AnyLayout(HStackLayout(spacing: 0))
                    : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    subtree(first, step: false)
                        .frame(width: axis == .horizontal ? firstLength : nil,
                               height: axis == .vertical ? firstLength : nil)
                    SplitDivider(axis: axis, ratio: ratio, available: available) { newRatio in
                        actions.setRatio(in: tab.id, at: path, newRatio)
                    }
                    subtree(second, step: true)
                }
            }
        }
    }

    private func subtree(_ node: SplitNode, step: Bool) -> PaneTreeView {
        PaneTreeView(node: node, path: SplitPath(steps: path.steps + [step]), tab: tab, visible: visible, chrome: chrome, actions: actions)
    }
}

/// The tinted gap between two panes. Drag to resize; double-click to make both sides equal.
/// An AppKit view, like NSSplitView's divider: mouse tracking and the resize cursor are exact,
/// and it sits beside AppKit terminal views without SwiftUI gesture arbitration.
struct SplitDivider: NSViewRepresentable {
    let axis: SplitAxis
    let ratio: Double
    let available: CGFloat
    let onChange: (Double) -> Void

    func makeNSView(context: Context) -> SplitDividerView { SplitDividerView() }

    func updateNSView(_ view: SplitDividerView, context: Context) {
        view.axis = axis
        view.ratio = ratio
        view.available = available
        view.onChange = onChange
        view.window?.invalidateCursorRects(for: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SplitDividerView, context: Context) -> CGSize? {
        axis == .horizontal
            ? CGSize(width: ChromeMetrics.paneGap, height: proposal.height ?? 0)
            : CGSize(width: proposal.width ?? 0, height: ChromeMetrics.paneGap)
    }
}

final class SplitDividerView: NSView {
    var axis: SplitAxis = .horizontal
    var ratio: Double = 0.5
    var available: CGFloat = 0
    var onChange: ((Double) -> Void)?

    private var dragStart: (point: NSPoint, ratio: Double)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStart = nil
            onChange?(0.5)
            return
        }
        dragStart = (event.locationInWindow, ratio)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, available > 0 else { return }
        let p = event.locationInWindow
        // Window coordinates grow upward; a split's first child is on top.
        let delta = axis == .horizontal ? p.x - start.point.x : start.point.y - p.y
        onChange?(start.ratio + Double(delta / available))
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { axis == .horizontal ? "Vertical split divider" : "Horizontal split divider" }
    override func accessibilityValue() -> Any? { NSNumber(value: ratio) }
}
