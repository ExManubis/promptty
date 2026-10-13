import SwiftUI
import WorkspaceModel

/// Lays out one tab's panes as rounded cards with draggable gaps between them. Every card sits
/// directly in one container, keyed by pane, so a split or a move never rebuilds a card (and never
/// re-hosts its terminal); only frames change.
///
/// Frame changes are animated Hyprland-style: a card takes its new frame at once (its terminal
/// resizes once) and is drawn through a scale and offset that carry it there from where it was.
struct PaneTreeView: View {
    let tab: WorkspaceModel.Tab
    let visible: Bool
    let chrome: WindowChromeModel
    let actions: ChromeActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = PaneMotionState()

    var body: some View {
        GeometryReader { geo in
            let full = tab.root.layout(in: CGRect(origin: .zero, size: geo.size), gap: ChromeMetrics.paneGap)
            // Zoomed, the pane fills the area; the others keep their frames, hidden, so they are
            // neither resized nor moved while they wait.
            let zoomed = tab.zoomedPaneID
            let frames = zoomed.map { full.panes.merging([$0: CGRect(origin: .zero, size: geo.size)]) { $1 } } ?? full.panes
            let dividers = zoomed == nil ? full.dividers : []
            let generation = motion.update(layout: frames, size: geo.size, animate: !reduceMotion && !chrome.resizingSplit)
            ZStack(alignment: .topLeading) {
                ForEach(dividers, id: \.path) { divider in
                    SplitDivider(axis: divider.axis, ratio: divider.ratio, available: divider.available) { newRatio in
                        actions.setRatio(in: tab.id, at: divider.path, newRatio)
                    } onDragging: { chrome.resizingSplit = $0 }
                    .frame(width: divider.frame.width, height: divider.frame.height)
                    .position(x: divider.frame.midX, y: divider.frame.midY)
                }
                ForEach(tab.root.leaves, id: \.self) { id in
                    if let pane = tab.pane(id), let frame = frames[id] {
                        let hidden = zoomed != nil && zoomed != id
                        PaneCard(pane: pane, tab: tab, visible: visible && !hidden, zoomed: zoomed == id, hidden: hidden, chrome: chrome, actions: actions)
                            .frame(width: frame.width, height: frame.height)
                            .modifier(PaneFlightEffect(flight: motion.flights[id]))
                            .opacity(hidden ? 0 : 1)
                            .allowsHitTesting(!hidden)
                            .accessibilityHidden(hidden)
                            .zIndex(zoomed == id ? 1 : 0)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                ForEach(closingPanes, id: \.id) { closing in
                    if let frame = motion.departed[closing.id] {
                        ClosingPaneCard(surface: closing.surface, chrome: chrome)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: generation) { content, progress in
                content.environment(\.paneMotionProgress, motion.record(progress))
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: PaneAnimation.paneDuration, timingCurve: PaneAnimation.paneCurve)
                }
            }
        }
    }

    private var closingPanes: [ClosingPane] {
        chrome.closingPanes.values.filter { $0.tab == tab.id }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }
}

/// The gap between two pane cards. Drag to resize; double-click to make both sides equal.
/// An AppKit view, like NSSplitView's divider: mouse tracking and the resize cursor are exact,
/// and it sits beside AppKit terminal views without SwiftUI gesture arbitration.
struct SplitDivider: NSViewRepresentable {
    let axis: SplitAxis
    let ratio: Double
    let available: CGFloat
    let onChange: (Double) -> Void
    /// True while the divider is being dragged: the panes follow the pointer without animating.
    let onDragging: (Bool) -> Void

    func makeNSView(context: Context) -> SplitDividerView { SplitDividerView() }

    func updateNSView(_ view: SplitDividerView, context: Context) {
        view.axis = axis
        view.ratio = ratio
        view.available = available
        view.onChange = onChange
        view.onDragging = onDragging
        view.window?.invalidateCursorRects(for: view)
    }

    /// A divider removed mid-drag (a zoom, a close) gets no mouse-up: the drag ends here, or the
    /// window would stay in its throttled resize mode.
    static func dismantleNSView(_ view: SplitDividerView, coordinator: ()) {
        view.endDrag()
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
    var onDragging: ((Bool) -> Void)?

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
        onDragging?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, available > 0 else { return }
        let p = event.locationInWindow
        // Window coordinates grow upward; a split's first child is on top.
        let delta = axis == .horizontal ? p.x - start.point.x : start.point.y - p.y
        onChange?(start.ratio + Double(delta / available))
    }

    override func mouseUp(with event: NSEvent) { endDrag() }

    func endDrag() {
        if dragStart != nil { onDragging?(false) }
        dragStart = nil
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { axis == .horizontal ? "Vertical split divider" : "Horizontal split divider" }
    override func accessibilityValue() -> Any? { NSNumber(value: ratio) }
}
