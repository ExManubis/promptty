import AppKit
import SwiftUI

/// What a copy looks like, as on Rex's code cards: just after the click the card catches the
/// light. Its edge brightens from the top-left and a soft band of light sweeps across it, left to
/// right and brightest along the bottom, then it is gone: about a third of a second.
enum CopyShine {
    /// After the click: the ✓ shows first.
    static let delay: TimeInterval = 0.06 * slowdown
    static let duration: TimeInterval = 0.34 * slowdown

    /// `PROMPTTY_SHINE_SLOW=10` plays it ten times slower, to look at in captures.
    private static let slowdown: Double = {
        #if DEBUG
        if let slow = ProcessInfo.processInfo.environment["PROMPTTY_SHINE_SLOW"].flatMap(Double.init) { return slow }
        #endif
        return 1
    }()
    /// The band's width, as a share of the card's.
    static let bandShare: CGFloat = 0.45

    static func rimPeak(dark: Bool) -> Double { dark ? 0.55 : 0.8 }
    static func bandPeak(dark: Bool) -> Double { dark ? 0.16 : 0.45 }

    /// Plays it over `rect` of `host` (a layer whose y runs down), in Core Animation: no work for
    /// the main thread while it runs.
    @MainActor
    static func play(in host: CALayer, rect: CGRect, cornerRadius: CGFloat, dark: Bool) {
        guard rect.width > 0, rect.height > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let card = CALayer()
        card.frame = rect
        card.cornerRadius = cornerRadius
        card.cornerCurve = .continuous
        card.masksToBounds = true

        // The band, faint at the top and full along the bottom.
        let fade = CAGradientLayer()
        fade.frame = card.bounds
        fade.colors = [NSColor.white.withAlphaComponent(0.4).cgColor, NSColor.white.cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        let sweep = CALayer()
        sweep.frame = card.bounds
        sweep.mask = fade
        let width = max(rect.width * bandShare, 40)
        let band = CAGradientLayer()
        band.bounds = CGRect(x: 0, y: 0, width: width, height: rect.height * 1.6)
        band.position = CGPoint(x: -width / 2, y: rect.height / 2)
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        let light = NSColor.white.withAlphaComponent(bandPeak(dark: dark)).cgColor
        band.colors = [NSColor.white.withAlphaComponent(0).cgColor, light, NSColor.white.withAlphaComponent(0).cgColor]
        // Leaning a little, as light does across glass.
        band.transform = CATransform3DMakeRotation(-.pi / 14, 0, 0, 1)
        band.opacity = 0
        sweep.addSublayer(band)
        card.addSublayer(sweep)

        // The edge, brightest at the top-left.
        let edge = CAShapeLayer()
        edge.path = CGPath(roundedRect: card.bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        edge.fillColor = nil
        edge.strokeColor = NSColor.white.cgColor
        edge.lineWidth = 1
        let edgeLight = CAGradientLayer()
        edgeLight.frame = card.bounds
        edgeLight.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.25).cgColor]
        edgeLight.startPoint = CGPoint(x: 0, y: 0)
        edgeLight.endPoint = CGPoint(x: 1, y: 1)
        edgeLight.mask = edge
        edgeLight.opacity = 0
        card.addSublayer(edgeLight)
        host.addSublayer(card)
        CATransaction.commit()

        let start = CACurrentMediaTime() + delay
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -width / 2
        move.toValue = rect.width + width / 2
        let bandLight = CAKeyframeAnimation(keyPath: "opacity")
        bandLight.values = [0, 1, 1, 0]
        bandLight.keyTimes = [0, 0.2, 0.7, 1]
        for animation in [move, bandLight] as [CAPropertyAnimation] {
            animation.beginTime = start
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.fillMode = .backwards
            band.add(animation, forKey: animation.keyPath)
        }
        let rim = CAKeyframeAnimation(keyPath: "opacity")
        rim.values = [0, rimPeak(dark: dark), 0]
        rim.keyTimes = [0, 0.35, 1]
        rim.beginTime = start
        rim.duration = duration
        rim.fillMode = .backwards
        edgeLight.add(rim, forKey: "rim")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration + 0.05) { card.removeFromSuperlayer() }
    }
}

/// The same over a SwiftUI card (a pane, on ⌘C): plays each time `trigger` changes.
struct CopyShineOverlay: View {
    let trigger: Int
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dark = colorScheme == .dark
        let radius = cornerRadius
        let still = reduceMotion
        Color.clear
            .keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { content, progress in
                content.overlay { if progress < 1, !still { CopyShineFrame(progress: progress, dark: dark, cornerRadius: radius) } }
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0)
                    LinearKeyframe(0, duration: CopyShine.delay)
                    CubicKeyframe(1, duration: CopyShine.duration)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

}

/// One frame of the shine, `progress` from 0 to 1.
private struct CopyShineFrame: View {
    let progress: CGFloat
    let dark: Bool
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Up, then down again: the edge peaks a third of the way, the band holds through the middle.
        let edge = progress < 0.35 ? progress / 0.35 : (1 - progress) / 0.65
        let band = progress < 0.2 ? progress / 0.2 : progress > 0.7 ? (1 - progress) / 0.3 : 1
        GeometryReader { geometry in
            let width = max(geometry.size.width * CopyShine.bandShare, 40)
            LinearGradient(colors: [.white.opacity(0), .white.opacity(CopyShine.bandPeak(dark: dark)), .white.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: width, height: geometry.size.height * 1.6)
                .rotationEffect(.radians(.pi / 14))
                .position(x: -width / 2 + progress * (geometry.size.width + width), y: geometry.size.height / 2)
                .opacity(Double(band))
                .mask(LinearGradient(colors: [.white.opacity(0.4), .white], startPoint: .top, endPoint: .bottom))
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.white, .white.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing),
                               lineWidth: 1)
                .opacity(CopyShine.rimPeak(dark: dark) * Double(max(0, edge)))
        }
        .blendMode(.plusLighter)
    }
}
