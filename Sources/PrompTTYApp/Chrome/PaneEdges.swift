import AppKit
import SwiftUI

// Drawn by SwiftUI, a gradient along a stroke is drawn by Core Graphics into a card-sized bitmap
// on the main thread, again at every frame the card changes size: while the sidebar slides, the
// pane edges took most of the main thread. As Core Animation layers (a gradient masked by the
// stroke), a new size only moves the layers, and the window server draws them.

/// The glass pane's edges, as Rex's: a light line around it, brightest along the top, shaded back
/// down at the bottom, with a faint glow just above the bottom edge.
struct PaneEdges: NSViewRepresentable {
    let panelColor: NSColor
    let dark: Bool
    /// How strongly the bottom edge is shaded toward the panel's color, in dark.
    let bottomShade: Double

    func makeNSView(context: Context) -> PaneEdgesView { PaneEdgesView() }

    func updateNSView(_ view: PaneEdgesView, context: Context) {
        view.update(panelColor: panelColor, dark: dark, bottomShade: bottomShade)
    }
}

final class PaneEdgesView: NSView {
    private let container = CALayer()
    /// Added to the color under it, so the light keeps the glass's hue.
    private let light = CAGradientLayer()
    private let lightMask = CAShapeLayer()
    private let shade = CAGradientLayer()
    private let shadeMask = CAShapeLayer()
    private let glow = CAGradientLayer()
    private let glowMask = CAShapeLayer()
    private static let lightWidth: CGFloat = 0.75
    private static let shadeWidth: CGFloat = 1
    private static let glowHeight: CGFloat = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Top-left origin, as SwiftUI's: the gradients run from the top down.
        container.isGeometryFlipped = true
        layer?.addSublayer(container)
        for (gradient, mask) in [(light, lightMask), (shade, shadeMask), (glow, glowMask)] {
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            gradient.mask = mask
            container.addSublayer(gradient)
        }
        for mask in [lightMask, shadeMask] {
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
        }
        lightMask.lineWidth = Self.lightWidth
        shadeMask.lineWidth = Self.shadeWidth
        glowMask.fillColor = NSColor.black.cgColor
        light.compositingFilter = "plusL"
        glow.compositingFilter = "plusL"
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(panelColor: NSColor, dark: Bool, bottomShade: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let white = { (alpha: CGFloat) in NSColor(white: 1, alpha: alpha).cgColor }
        light.colors = (dark ? [0.04, 0.05, 0.05, 0] : [0.45, 0.2, 0.1, 0.1]).map(white)
        light.locations = [0, 0.03, 0.97, 1]
        // From the panel's color, transparent: the edge fades into it rather than through black.
        let panel = panelColor.usingColorSpace(.sRGB) ?? panelColor
        shade.colors = [panel.withAlphaComponent(0).cgColor, panel.withAlphaComponent(dark ? bottomShade : 0).cgColor]
        shade.locations = [0.985, 1]
        glow.colors = [white(0), white(dark ? 0.05 : 0.08)]
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.paneCornerRadius, style: .continuous)
        // As `strokeBorder`: the line lies inside the edge.
        for (gradient, mask, width) in [(light, lightMask, Self.lightWidth), (shade, shadeMask, Self.shadeWidth)] {
            gradient.frame = bounds
            mask.frame = bounds
            mask.path = shape.inset(by: width / 2).path(in: bounds).cgPath
        }
        // The glow's band along the bottom, clipped to the card's corners.
        glow.frame = CGRect(x: 0, y: bounds.height - Self.glowHeight, width: bounds.width, height: Self.glowHeight)
        glowMask.frame = CGRect(x: 0, y: -glow.frame.minY, width: bounds.width, height: bounds.height)
        glowMask.path = shape.path(in: bounds).cgPath
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [container, light, lightMask, shade, shadeMask, glow, glowMask] { layer.contentsScale = scale }
    }
}
