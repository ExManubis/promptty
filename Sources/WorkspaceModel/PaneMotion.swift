import CoreGraphics

/// The geometry of pane animations. A pane is laid out at its final frame at once (its terminal
/// resizes once) and drawn through a scale and offset that carry it from where it was to there.
public enum PaneMotion {
    /// One pane's trip from where it is drawn now to its new frame.
    public struct Flight: Equatable, Sendable {
        public var from: CGRect
        public var to: CGRect
        /// A new pane: it grows out of a smaller copy of its frame and fades in.
        public var appearing: Bool

        public init(from: CGRect, to: CGRect, appearing: Bool) {
            self.from = from
            self.to = to
            self.appearing = appearing
        }

        public func frame(at progress: CGFloat) -> CGRect { PaneMotion.interpolate(from, to, progress) }

        public func opacity(at progress: CGFloat) -> CGFloat {
            appearing ? min(1, max(0, progress / 0.6)) : 1
        }
    }

    /// Scale about the center, then offset of the center.
    public struct Transform: Equatable, Sendable {
        public var scaleX: CGFloat
        public var scaleY: CGFloat
        public var offsetX: CGFloat
        public var offsetY: CGFloat

        public static let identity = Transform(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0)
    }

    /// `t` of the way from `a` to `b`. `t` may run past 1 when the curve overshoots.
    public static func interpolate(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    /// The transform that draws a view laid out at `layout` so it covers `visual`.
    public static func transform(drawing layout: CGRect, as visual: CGRect) -> Transform {
        guard layout.width > 0, layout.height > 0 else { return .identity }
        return Transform(
            scaleX: visual.width / layout.width,
            scaleY: visual.height / layout.height,
            offsetX: visual.midX - layout.midX,
            offsetY: visual.midY - layout.midY
        )
    }

    /// Flights for every pane in `next`: a pane drawn now starts where it is (`current`); a new
    /// pane starts as its frame scaled by `popScale` about the center.
    public static func flights(from current: [PaneID: CGRect], to next: [PaneID: CGRect], popScale: CGFloat) -> [PaneID: Flight] {
        next.reduce(into: [:]) { result, entry in
            let (id, frame) = entry
            if let now = current[id] {
                result[id] = Flight(from: now, to: frame, appearing: false)
            } else {
                let from = frame.insetBy(dx: frame.width * (1 - popScale) / 2, dy: frame.height * (1 - popScale) / 2)
                result[id] = Flight(from: from, to: frame, appearing: true)
            }
        }
    }
}
