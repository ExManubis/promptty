import GhosttyBridge
import SwiftUI
import WorkspaceModel

/// Hyprland-style motion: panes pop in, glide to new frames and shrink away when closed; tabs
/// cross-fade. Always on, except under the system's Reduce Motion setting.
enum PaneAnimation {
    /// Hyprland's default bezier (0.05, 0.9, 0.1, 1.05): a fast start and a slight overshoot.
    static let paneCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.05, y: 0.9), endControlPoint: UnitPoint(x: 0.1, y: 1.05))
    static let paneDuration: TimeInterval = 0.35
    /// A new pane grows out of, and a closing pane shrinks into, this fraction of its frame.
    static let popScale: CGFloat = 0.85
    static let closeDuration: TimeInterval = 0.2
    /// Tabs only fade: moving a whole terminal reads as scrolling it.
    static let tabCurve = UnitCurve.easeOut
    static let tabDuration: TimeInterval = 0.2
    static let focusFade = Animation.easeOut(duration: 0.18)
}

extension EnvironmentValues {
    /// How far the current pane animation has run: 0 at its start, 1 at rest (may overshoot 1).
    @Entry var paneMotionProgress: CGFloat = 1
    /// The sidebar is collapsed out of sight (its peek shows the tabs instead).
    @Entry var sidebarOutOfSight = false
    /// How far the current tab cross-fade has run: 0 at its start, 1 at rest.
    @Entry var tabFadeProgress: CGFloat = 1
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

/// Which tab fades out when the selection changes.
@MainActor
final class TabFadeState {
    private(set) var generation = 0
    private(set) var outgoing: TabID?
    private var shown: TabID?

    /// A new generation restarts the fade. A tab that was closed has nothing to fade out.
    func update(selected: TabID?, tabs: [TabID], animate: Bool) -> Int {
        guard selected != shown else { return generation }
        defer { shown = selected }
        if animate, let old = shown, tabs.contains(old), selected != nil {
            outgoing = old
            generation += 1
        } else {
            outgoing = nil
        }
        return generation
    }
}

/// One tab's panes in the stack of tabs: the selected tab is shown, the tab it replaced stays
/// visible underneath while the new one fades in, and every other tab is hidden.
struct TabPanes: View {
    let tab: WorkspaceModel.Tab
    let selected: Bool
    let outgoing: Bool
    let chrome: WindowChromeModel
    let actions: ChromeActions
    @Environment(\.tabFadeProgress) private var progress

    var body: some View {
        let opacity = PaneMotion.tabFadeOpacity(selected: selected, outgoing: outgoing, progress: progress)
        PaneTreeView(tab: tab, visible: selected || opacity > 0, chrome: chrome, actions: actions)
            .opacity(Double(opacity))
            .zIndex(selected ? 1 : 0)
            .allowsHitTesting(selected)
            .accessibilityHidden(!selected)
    }
}
