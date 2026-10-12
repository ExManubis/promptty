import CoreGraphics

/// Where a tab's panes and split dividers sit on screen: each pane a frame, each split a gap
/// between its two sides. y grows downward: `first` of a vertical split is on top.
public struct SplitLayout: Equatable, Sendable {
    public struct Divider: Equatable, Sendable {
        /// The split this divider resizes (the path `SplitNode.resizing(at:ratio:)` takes).
        public let path: SplitPath
        public let axis: SplitAxis
        public let ratio: Double
        /// The length the two sides share (the split's extent minus the gap), which turns a drag
        /// distance into a ratio.
        public let available: CGFloat
        public let frame: CGRect

        public init(path: SplitPath, axis: SplitAxis, ratio: Double, available: CGFloat, frame: CGRect) {
            self.path = path
            self.axis = axis
            self.ratio = ratio
            self.available = available
            self.frame = frame
        }
    }

    public var panes: [PaneID: CGRect]
    /// Each split before the splits inside it, `first` subtrees before `second`.
    public var dividers: [Divider]
}

extension SplitNode {
    /// Lays the tree out in `rect` with `gap` points between the two sides of every split. The
    /// first side of a split gets `ratio` of the space left after the gap, rounded to whole points.
    public func layout(in rect: CGRect, gap: CGFloat) -> SplitLayout {
        var result = SplitLayout(panes: [:], dividers: [])
        place(in: rect, gap: gap, path: [], into: &result)
        return result
    }

    private func place(in rect: CGRect, gap: CGFloat, path: [Bool], into result: inout SplitLayout) {
        switch self {
        case .leaf(let id):
            result.panes[id] = rect
        case .split(let axis, let ratio, let first, let second):
            let total = axis == .horizontal ? rect.width : rect.height
            let available = max(0, total - gap)
            let firstLength = (available * ratio).rounded()
            let secondLength = max(0, total - firstLength - gap)
            let firstRect: CGRect
            let divider: CGRect
            let secondRect: CGRect
            switch axis {
            case .horizontal:
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstLength, height: rect.height)
                divider = CGRect(x: rect.minX + firstLength, y: rect.minY, width: gap, height: rect.height)
                secondRect = CGRect(x: rect.minX + firstLength + gap, y: rect.minY, width: secondLength, height: rect.height)
            case .vertical:
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLength)
                divider = CGRect(x: rect.minX, y: rect.minY + firstLength, width: rect.width, height: gap)
                secondRect = CGRect(x: rect.minX, y: rect.minY + firstLength + gap, width: rect.width, height: secondLength)
            }
            result.dividers.append(SplitLayout.Divider(
                path: SplitPath(steps: path), axis: axis, ratio: ratio, available: available, frame: divider
            ))
            first.place(in: firstRect, gap: gap, path: path + [false], into: &result)
            second.place(in: secondRect, gap: gap, path: path + [true], into: &result)
        }
    }
}
