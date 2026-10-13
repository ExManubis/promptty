import AppKit
import PaneActivity
import SwiftUI
import WorkspaceModel

/// A program's logo in its brand color, or the terminal symbol for a shell or an unknown program.
struct ProgramIcon: View {
    let program: Program?
    var size: CGFloat = 14
    /// Shown when no program is recognised.
    var fallbackSymbol = "terminal"
    /// The logo's color, in place of the brand's (on a brand-colored tile).
    var tint: Color?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let program, let logo = program.logo, program.fullColorLogo {
            // In its own colors, whatever the tile.
            Image("logo-\(logo)")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel(program.name)
        } else if let program, let logo = program.logo {
            Image("logo-\(logo)")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(tint ?? color(for: program))
                .accessibilityLabel(program.name)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.92, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    /// The brand color, unless it would be hard to see on this background (a black logo on a
    /// dark pane): below a 2.5:1 contrast ratio the text color is used instead.
    private func color(for program: Program) -> Color {
        guard let hex = program.color else { return .primary }
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        // Typical dark and light pane backgrounds.
        let background = colorScheme == .dark ? 0.012 : 0.87
        let ratio = (max(luminance, background) + 0.05) / (min(luminance, background) + 0.05)
        return ratio < 2.5 ? .primary : Color(red: r, green: g, blue: b)
    }
}

/// A pane's or tab's activity as a dot: green while something runs, blue for what finished
/// unseen, red for what failed, a pulsing orange when a program wants the user; an orange shield
/// when an agent asks for permission. Only the orange dot moves.
struct ActivityIndicator: View {
    let display: PaneActivity.Display

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch display {
            case .idle:
                Color.clear
            case .permission:
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ProgramStack.color(for: display))
                    .fixedSize()
            case .attention where !reduceMotion:
                // Pulses until seen, in Core Animation (see `PulsingDot`).
                PulsingDot(color: NSColor(ProgramStack.color(for: display)))
            default:
                Circle().fill(ProgramStack.color(for: display)).frame(width: 7, height: 7)
            }
        }
        .frame(width: 9, height: 9)
        .accessibilityElement()
        .accessibilityLabel(Self.label(for: display))
        .accessibilityHidden(display == .idle)
    }

    static func label(for display: PaneActivity.Display) -> String {
        switch display {
        case .idle: ""
        case .running: "Running"
        case .working: "Working"
        case .finished: "Finished"
        case .failed(let code): "Failed with exit code \(code)"
        case .attention: "Needs attention"
        case .permission: "Needs permission"
        }
    }
}

/// A pane's progress report as a small ring: filled to the percent for a set one, red for an
/// error, yellow for a pause. An indeterminate report shows none (`ProgressRing.shows`).
struct ProgressRing: View {
    let progress: PaneProgress

    static let size: CGFloat = 12

    /// Whether a report shows a ring: an indeterminate one would only spin, which says nothing.
    static func shows(_ progress: PaneProgress) -> Bool { progress.kind != .indeterminate }
    private static let line: CGFloat = 2

    private var color: Color {
        switch progress.kind {
        case .set, .indeterminate: Color.accentColor
        case .error: Color.red
        case .pause: Color.yellow
        }
    }

    var body: some View {
        ZStack {
            Circle().strokeBorder(color.opacity(0.28), lineWidth: Self.line)
            if let fraction = progress.fraction {
                Circle()
                    .trim(from: 0, to: max(fraction, 0.02))
                    .stroke(color, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(Self.line / 2)
            } else {
                // An error or a pause without a percent.
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(color, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(Self.line / 2)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityElement()
        .accessibilityLabel(Self.label(for: progress))
    }

    static func label(for progress: PaneProgress) -> String {
        let percent = progress.fraction.map { " \(Int(($0 * 100).rounded())) percent" } ?? ""
        switch progress.kind {
        case .set: return "Progress\(percent)"
        case .indeterminate: return "In progress"
        case .error: return "Progress failed\(percent)"
        case .pause: return "Progress paused\(percent)"
        }
    }
}

/// The ring of one pane's box, observed on its own: only the ring redraws as the report changes.
struct StatusProgressRing: View {
    let status: PaneStatus

    var body: some View {
        if let progress = status.progress, ProgressRing.shows(progress) { ProgressRing(progress: progress) }
    }
}

/// The ring of a tab: the report of its first pane that has one to show (the focused pane first).
struct TabProgressRing: View {
    let panes: [PaneID]
    let actions: ChromeActions

    var body: some View {
        if let progress = panes.lazy.compactMap({ actions.progress(for: $0) }).first(where: ProgressRing.shows) {
            ProgressRing(progress: progress)
        }
    }
}

/// A tab's panes as a stack of tiles, like Rex's: the focused pane's logo on a light card in
/// front, tilted a little, the other panes' cards peeking out behind it, each edge in the color of
/// its activity. A tab with one pane is one tile.
struct ProgramStack: View {
    struct Card: Identifiable {
        let id: AnyHashable
        let program: Program?
        let display: PaneActivity.Display
    }

    /// The focused pane first, then the others in order.
    let cards: [Card]

    static let width: CGFloat = 18
    static let height: CGFloat = 15
    /// How far each card behind shows past the one in front: enough for its logo.
    static let step: CGFloat = 8
    static let maxCards = 3
    /// The front card's tilt; each card behind turns a little less.
    static let tilt: Double = -5

    var body: some View {
        let shown = Array(cards.prefix(Self.maxCards))
        ZStack(alignment: .leading) {
            ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { depth, card in
                let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                // Every card is its program's tile; on the cards behind, the logo sits where the
                // card shows, at its right edge.
                shape.fill(Self.background(for: card.program))
                    .overlay(alignment: depth == 0 ? .center : .trailing) {
                        logo(of: card.program, size: depth == 0 ? 11 : 9)
                            .padding(.trailing, depth == 0 ? 0 : 1.5)
                    }
                    // A faint rim, so a dark tile stands out on a dark sidebar.
                    .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5).padding(0.75))
                .overlay(shape.strokeBorder(.black.opacity(0.55), lineWidth: 1))
                .frame(width: Self.width, height: Self.height)
                .rotationEffect(.degrees(Self.tilt + Double(depth) * 2.5))
                // Each card shades the one behind it.
                .shadow(color: .black.opacity(0.3), radius: 1, x: 0.5)
                .offset(x: CGFloat(depth) * Self.step)
            }
        }
        .frame(width: Self.width + CGFloat(max(shown.count - 1, 0)) * Self.step + 2, height: Self.height + 3, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel(Self.label(for: shown))
    }

    @ViewBuilder
    private func logo(of program: Program?, size: CGFloat) -> some View {
        if program?.logo != nil {
            // On a brand tile in the brand's pairing; on the dark tile in the brand's color, as on
            // a dark background.
            ProgramIcon(program: program, size: size, tint: program?.tile.map { Self.color($0.foreground) })
                .environment(\.colorScheme, .dark)
        } else {
            // A shell or an unknown program: the prompt itself, as Rex shows it.
            Text(">_")
                .font(.system(size: size * 0.73, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.85))
                .accessibilityHidden(true)
        }
    }

    /// The default tile: dark, like a terminal.
    static let darkTile = Color(red: 0.13, green: 0.13, blue: 0.145)

    static func background(for program: Program?) -> Color {
        program?.tile.map { color($0.background) } ?? darkTile
    }

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func color(for display: PaneActivity.Display) -> Color {
        switch display {
        case .idle: Color(white: 0.55)
        case .running, .working: .green
        case .finished: .blue
        case .failed: .red
        case .attention, .permission: .orange
        }
    }

    private static func label(for cards: [Card]) -> String {
        let names = cards.map { $0.program?.name ?? "Terminal" }
        return cards.count == 1 ? names[0] : "\(cards.count) panes: " + names.joined(separator: ", ")
    }
}

// MARK: Looping animations in Core Animation
//
// A SwiftUI `repeatForever` animation is driven by SwiftUI on the main thread: every frame it
// updates the view, and every update waits for the window server to take the window's last
// frame. The main thread also takes the keys and presents the terminal's frames, so a looping
// dot made typing, and the agent's own animation, stutter. It runs in the window server instead,
// and costs the app nothing per frame.

/// The activity dot that pulses while a program waits for the user.
private struct PulsingDot: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> LoopingLayerView {
        let view = LoopingLayerView()
        view.configure = { layer, bounds in
            let dot = layer.sublayers?.first ?? {
                let dot = CALayer()
                layer.addSublayer(dot)
                return dot
            }()
            dot.frame = CGRect(x: (bounds.width - 7) / 2, y: (bounds.height - 7) / 2, width: 7, height: 7)
            dot.cornerRadius = 3.5
            return dot
        }
        update(view)
        return view
    }

    func updateNSView(_ view: LoopingLayerView, context: Context) { update(view) }

    private func update(_ view: LoopingLayerView) {
        // Only a new color restarts it: SwiftUI updates the dot whenever its row redraws, and a
        // restart would make it jump.
        let key = "\(color)"
        guard view.key != key else { return }
        view.key = key
        let color = color
        view.animate = { dot in
            dot.backgroundColor = color.cgColor
            let animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = 0.85
            animation.toValue = 1.15
            animation.duration = 0.9
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return animation
        }
        view.restart()
    }
}

/// A view whose one sublayer loops an animation, restarted when it is laid out again or joins a
/// window (Core Animation drops animations from layers that leave one).
final class LoopingLayerView: NSView {
    /// Makes or updates the animated sublayer for the view's bounds, and returns it.
    var configure: ((CALayer, CGRect) -> CALayer)?
    /// The animation to loop on that sublayer.
    var animate: ((CALayer) -> CAAnimation)?
    /// What the animation was made for; its owner restarts it only when this changes.
    var key: String?
    private var laidOutSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        restart()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restart()
    }

    func restart() {
        guard let layer, let configure, let animate, bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let target = configure(layer, bounds)
        target.removeAnimation(forKey: "loop")
        target.add(animate(target), forKey: "loop")
        CATransaction.commit()
    }
}
