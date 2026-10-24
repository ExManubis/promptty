import PaneActivity
import QuartzCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A pane's or tab's activity as a dot: green while something runs, blue for what finished
/// unseen, red for what failed, a pulsing orange when a program wants the user; an orange shield
/// when an agent asks for permission. Only the orange dot moves.
public struct ActivityIndicator: View {
    let display: PaneActivity.Display
    /// The tab printed while unseen: shown when nothing more urgent is (a hollow ring around the
    /// running dot, or a ring alone).
    var newOutput: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(display: PaneActivity.Display, newOutput: Bool = false) {
        self.display = display
        self.newOutput = newOutput
    }

    public var body: some View {
        Group {
            switch display {
            case .idle where newOutput, .running where newOutput:
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .overlay { if display == .running { Circle().fill(ProgramStack.color(for: display)).padding(2.5) } }
                    .frame(width: 9, height: 9)
                    .help("New output")
            case .idle:
                Color.clear
            case .permission:
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ProgramStack.color(for: display))
                    .fixedSize()
            case .attention where !reduceMotion:
                // Pulses until seen, in Core Animation (see `PulsingDot`).
                PulsingDot(color: PlatformColor(ProgramStack.color(for: display)))
            default:
                Circle().fill(ProgramStack.color(for: display)).frame(width: 7, height: 7)
            }
        }
        .frame(width: 9, height: 9)
        .accessibilityElement()
        .accessibilityLabel([Self.label(for: display), newOutput ? "New output" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHidden(display == .idle && !newOutput)
    }

    public static func label(for display: PaneActivity.Display) -> String {
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
public struct ProgressRing: View {
    let progress: PaneProgress

    public static let size: CGFloat = 12

    public init(progress: PaneProgress) {
        self.progress = progress
    }

    /// Whether a report shows a ring: an indeterminate one would only spin, which says nothing.
    public static func shows(_ progress: PaneProgress) -> Bool { progress.kind != .indeterminate }
    private static let line: CGFloat = 2

    private var color: Color {
        switch progress.kind {
        case .set, .indeterminate: Color.accentColor
        case .error: Color.red
        case .pause: Color.yellow
        }
    }

    public var body: some View {
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

    public static func label(for progress: PaneProgress) -> String {
        let percent = progress.fraction.map { " \(Int(($0 * 100).rounded())) percent" } ?? ""
        switch progress.kind {
        case .set: return "Progress\(percent)"
        case .indeterminate: return "In progress"
        case .error: return "Progress failed\(percent)"
        case .pause: return "Progress paused\(percent)"
        }
    }
}

/// Rex's "•••" while an agent works: three dots brightening in turn. Looped in Core Animation
/// (see `LoopingLayerView`), so it costs the main thread nothing per frame; still under Reduce
/// Motion.
public struct WorkingDots: View {
    var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(scale: CGFloat = 1) {
        self.scale = scale
    }

    public var body: some View {
        WorkingDotsLayer(color: colorScheme == .dark ? .white : .black, animated: !reduceMotion, dotSize: 4 * scale)
            .frame(width: 18 * scale, height: 6 * scale)
            .accessibilityElement()
            .accessibilityLabel("Working")
    }
}

// MARK: Looping animations in Core Animation
//
// A SwiftUI `repeatForever` animation is driven by SwiftUI on the main thread: every frame it
// updates the view, and every update waits for the window server to take the window's last
// frame. The main thread also takes the keys and presents the terminal's frames, so a looping
// dot made typing, and the agent's own animation, stutter. It runs in the window server instead,
// and costs the app nothing per frame.

#if os(macOS)
typealias PlatformColor = NSColor
typealias PlatformView = NSView
#else
typealias PlatformColor = UIColor
typealias PlatformView = UIView
#endif

/// A view whose own layer hosts sublayers, on either platform: AppKit's is made layer-backed.
class LayerHostView: PlatformView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(macOS)
        wantsLayer = true
        #else
        isUserInteractionEnabled = false
        backgroundColor = .clear
        #endif
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var hostLayer: CALayer? { layer }

    /// Called when the view is laid out again.
    func laidOut() {}
    /// Called when the view joins a window.
    func joinedWindow() {}

    #if os(macOS)
    override func layout() {
        super.layout()
        laidOut()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        joinedWindow()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        laidOut()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        joinedWindow()
    }
    #endif
}

/// The activity dot that pulses while a program waits for the user.
@MainActor
private struct PulsingDot {
    let color: PlatformColor

    private func make() -> LoopingLayerView {
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

    #if os(macOS)
    struct Representable: NSViewRepresentable {
        let dot: PulsingDot
        func makeNSView(context: Context) -> LoopingLayerView { dot.make() }
        func updateNSView(_ view: LoopingLayerView, context: Context) { dot.update(view) }
    }
    #else
    struct Representable: UIViewRepresentable {
        let dot: PulsingDot
        func makeUIView(context: Context) -> LoopingLayerView { dot.make() }
        func updateUIView(_ view: LoopingLayerView, context: Context) { dot.update(view) }
    }
    #endif
}

extension PulsingDot: View {
    var body: some View { Representable(dot: self) }
}

/// A view whose one sublayer loops an animation, restarted when it is laid out again or joins a
/// window (Core Animation drops animations from layers that leave one).
final class LoopingLayerView: LayerHostView {
    /// Makes or updates the animated sublayer for the view's bounds, and returns it.
    var configure: ((CALayer, CGRect) -> CALayer)?
    /// The animation to loop on that sublayer.
    var animate: ((CALayer) -> CAAnimation)?
    /// What the animation was made for; its owner restarts it only when this changes.
    var key: String?
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        hostLayer?.masksToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func laidOut() {
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        restart()
    }

    override func joinedWindow() { restart() }

    func restart() {
        guard let layer = hostLayer, let configure, let animate, bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let target = configure(layer, bounds)
        target.removeAnimation(forKey: "loop")
        target.add(animate(target), forKey: "loop")
        CATransaction.commit()
    }
}

@MainActor
private struct WorkingDotsLayer {
    let color: PlatformColor
    let animated: Bool
    let dotSize: CGFloat

    private func update(_ view: DotsView) {
        guard view.color != color || view.animated != animated || view.size != dotSize else { return }
        view.color = color
        view.animated = animated
        view.size = dotSize
        view.restart()
    }

    #if os(macOS)
    struct Representable: NSViewRepresentable {
        let dots: WorkingDotsLayer
        func makeNSView(context: Context) -> DotsView { DotsView() }
        func updateNSView(_ view: DotsView, context: Context) { dots.update(view) }
    }
    #else
    struct Representable: UIViewRepresentable {
        let dots: WorkingDotsLayer
        func makeUIView(context: Context) -> DotsView { DotsView() }
        func updateUIView(_ view: DotsView, context: Context) { dots.update(view) }
    }
    #endif

    final class DotsView: LayerHostView {
        var color: PlatformColor = .white
        var animated = true
        var size: CGFloat = 4
        private var dots: [CALayer] = []
        private var laidOutSize: CGSize = .zero

        /// Only a new size restarts the dots, as `LoopingLayerView` does: the sidebar lays its rows
        /// out again often, and a restart makes the dots jump.
        override func laidOut() {
            guard bounds.size != laidOutSize else { return }
            laidOutSize = bounds.size
            restart()
        }

        override func joinedWindow() { restart() }

        func restart() {
            guard let layer = hostLayer, bounds.width > 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if dots.isEmpty {
                dots = (0..<3).map { _ in CALayer() }
                dots.forEach(layer.addSublayer)
            }
            let gap = (bounds.width - 3 * size) / 2
            let now = CACurrentMediaTime()
            for (index, dot) in dots.enumerated() {
                dot.frame = CGRect(x: CGFloat(index) * (size + gap), y: (bounds.height - size) / 2, width: size, height: size)
                dot.cornerRadius = size / 2
                dot.backgroundColor = color.cgColor
                dot.removeAllAnimations()
                dot.opacity = animated ? 0.25 : 0.6
                guard animated else { continue }
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = [0.25, 0.9, 0.25, 0.25]
                pulse.keyTimes = [0, 0.25, 0.55, 1]
                pulse.duration = 1.2
                pulse.repeatCount = .infinity
                pulse.beginTime = now + Double(index) * 0.2
                pulse.fillMode = .backwards
                dot.add(pulse, forKey: "pulse")
            }
            CATransaction.commit()
        }
    }
}

extension WorkingDotsLayer: View {
    var body: some View { Representable(dots: self) }
}
