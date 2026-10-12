import GhosttyBridge
import SwiftUI
import WorkspaceModel

/// Hyprland-style motion: panes pop in, glide to new frames, shrink away when closed, and tabs
/// slide like workspaces. Always on, except under the system's Reduce Motion setting.
enum PaneAnimation {
    /// Hyprland's default bezier (0.05, 0.9, 0.1, 1.05): a fast start and a slight overshoot.
    static let paneCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.05, y: 0.9), endControlPoint: UnitPoint(x: 0.1, y: 1.05))
    static let paneDuration: TimeInterval = 0.35
    /// A new pane grows out of, and a closing pane shrinks into, this fraction of its frame.
    static let popScale: CGFloat = 0.85
    static let closeDuration: TimeInterval = 0.2
    /// Tabs slide without overshoot: a whole pane area bouncing past its place reads as a wobble.
    static let tabCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.16, y: 1), endControlPoint: UnitPoint(x: 0.3, y: 1))
    static let tabDuration: TimeInterval = 0.3
    static let focusFade = Animation.easeOut(duration: 0.18)
}

extension EnvironmentValues {
    /// How far the current pane animation has run: 0 at its start, 1 at rest (may overshoot 1).
    @Entry var paneMotionProgress: CGFloat = 1
    /// How far the current tab slide has run: 0 at its start, 1 at rest.
    @Entry var tabSlideProgress: CGFloat = 1
}

/// One tab's pane animation bookkeeping. A plain reference held in `@State`: the view writes it
/// while it renders, so it must not be observable.
@MainActor
final class PaneMotionState {
    private(set) var flights: [PaneID: PaneMotion.Flight] = [:]
    /// Where panes that just left the layout were last drawn, for their closing animation.
    private(set) var departed: [PaneID: CGRect] = [:]
    private(set) var generation = 0
    private var laidOut: [PaneID: CGRect] = [:]
    private var size: CGSize = .zero
    private var progress: CGFloat = 1

    /// Takes the frames the tab is now laid out at. If they changed and `animate` is set (and the
    /// tab did not just resize, which should track the window directly), starts flights from where
    /// each pane is drawn now and returns a new generation, which restarts the animation.
    func update(layout: [PaneID: CGRect], size: CGSize, animate: Bool) -> Int {
        guard layout != laidOut || size != self.size else { return generation }
        let drawn = drawnFrames()
        if departed.count > 32 { departed = [:] }
        for (id, frame) in drawn where layout[id] == nil { departed[id] = frame }
        for id in layout.keys { departed[id] = nil }
        if animate, size == self.size, !laidOut.isEmpty {
            flights = PaneMotion.flights(from: drawn, to: layout, popScale: PaneAnimation.popScale)
            generation += 1
        } else {
            flights = [:]
        }
        laidOut = layout
        self.size = size
        return generation
    }

    /// Notes the animation's progress (so a change mid-flight starts from where panes are drawn).
    func record(_ progress: CGFloat) -> CGFloat {
        self.progress = progress
        return progress
    }

    private func drawnFrames() -> [PaneID: CGRect] {
        laidOut.reduce(into: [:]) { result, entry in
            result[entry.key] = flights[entry.key]?.frame(at: progress) ?? entry.value
        }
    }
}

/// Draws a card laid out at its flight's destination where the flight currently is. Always applies
/// the same modifiers (identity at rest) so the card, and its terminal host, keep their identity.
struct PaneFlightEffect: ViewModifier {
    let flight: PaneMotion.Flight?
    @Environment(\.paneMotionProgress) private var progress

    func body(content: Content) -> some View {
        let t = flight.map { PaneMotion.transform(drawing: $0.to, as: $0.frame(at: progress)) } ?? .identity
        content
            .scaleEffect(x: t.scaleX, y: t.scaleY)
            .offset(x: t.offsetX, y: t.offsetY)
            .opacity(Double(flight?.opacity(at: progress) ?? 1))
    }
}

/// A pane that was just closed: its terminal stays alive briefly so the card can shrink away.
struct ClosingPane {
    let id: PaneID
    let tab: TabID
    let surface: TerminalSurfaceView
}

struct ClosingPaneCard: View {
    let surface: TerminalSurfaceView
    let chrome: WindowChromeModel
    @State private var gone = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.paneCornerRadius, style: .continuous)
        PaneHost(surface: surface, visible: true)
            .background { shape.fill(Color(nsColor: chrome.panelColor)) }
            .overlay { shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1) }
            .environment(\.colorScheme, chrome.panelIsDark ? .dark : .light)
            .scaleEffect(gone ? PaneAnimation.popScale : 1)
            .opacity(gone ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeIn(duration: PaneAnimation.closeDuration)) { gone = true }
            }
    }
}

/// Which tab slides out when the selection changes, and which way.
@MainActor
final class TabSlideState {
    private(set) var generation = 0
    private(set) var outgoing: TabID?
    /// +1 when the new tab comes after the old one in the tab list, -1 when before.
    private(set) var direction: CGFloat = 1
    private var shown: TabID?

    func update(selected: TabID?, order: [TabID], animate: Bool) -> Int {
        guard selected != shown else { return generation }
        defer { shown = selected }
        if animate, let old = shown, let from = order.firstIndex(of: old),
           let selected, let to = order.firstIndex(of: selected) {
            outgoing = old
            direction = to > from ? 1 : -1
            generation += 1
        } else {
            outgoing = nil
        }
        return generation
    }
}

/// One tab's panes in the stack of tabs: the selected tab is shown, the tab it replaced stays
/// visible while it slides out, and every other tab is hidden.
struct TabPanes: View {
    let tab: WorkspaceModel.Tab
    let selected: Bool
    let outgoing: Bool
    /// +1 when the selection moved later in the tab list, -1 when earlier.
    let direction: CGFloat
    /// The slide's axis and length: along x for a tab strip, along y for the sidebar.
    let shift: CGSize
    let chrome: WindowChromeModel
    let actions: ChromeActions
    @Environment(\.tabSlideProgress) private var progress

    var body: some View {
        let sliding = progress < 1
        let showing = selected || (outgoing && sliding)
        let fraction = PaneMotion.tabSlideFraction(selected: selected, outgoing: outgoing, direction: direction, progress: progress)
        PaneTreeView(tab: tab, visible: showing, chrome: chrome, actions: actions)
            .offset(x: shift.width * fraction, y: shift.height * fraction)
            .opacity(showing ? 1 : 0)
            .allowsHitTesting(selected)
            .accessibilityHidden(!selected)
    }
}
