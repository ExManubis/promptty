import CoreGraphics

/// `horizontal` lays children side by side; `vertical` stacks them.
public enum SplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

/// Where a new split goes, and which way focus moves.
public enum SplitDirection: Sendable, CaseIterable {
    case left, right, up, down
}

/// The edge of a pane that a dragged pane is dropped on.
public enum PaneEdge: Sendable, CaseIterable {
    case left, right, top, bottom
}

/// Addresses a split inside a tree: each step picks `first` (false) or `second` (true).
public struct SplitPath: Hashable, Sendable {
    public var steps: [Bool]
    public init(steps: [Bool]) { self.steps = steps }
}

/// The layout of one tab: a binary tree of panes. A value type, so every operation returns a new tree.
public indirect enum SplitNode: Equatable, Sendable {
    case leaf(PaneID)
    /// `ratio` is the share of `first` along `axis`.
    case split(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)

    public static let minRatio = 0.1
    public static let maxRatio = 0.9

    static func clamp(_ ratio: Double) -> Double { min(maxRatio, max(minRatio, ratio)) }

    /// Panes in reading order: left to right, top to bottom.
    public var leaves: [PaneID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let first, let second): return first.leaves + second.leaves
        }
    }

    public func contains(_ pane: PaneID) -> Bool {
        switch self {
        case .leaf(let id): return id == pane
        case .split(_, _, let first, let second): return first.contains(pane) || second.contains(pane)
        }
    }

    /// Replaces `pane` with an even split of `pane` and `newPane`, `newPane` on the `direction` side.
    public func splitting(_ pane: PaneID, direction: SplitDirection, newPane: PaneID) -> SplitNode {
        let edge: PaneEdge
        switch direction {
        case .left: edge = .left
        case .right: edge = .right
        case .up: edge = .top
        case .down: edge = .bottom
        }
        return inserting(newPane, at: pane, edge: edge)
    }

    /// Splits `target` evenly with `pane` placed on `edge`. Returns self if `target` is not in the tree.
    public func inserting(_ pane: PaneID, at target: PaneID, edge: PaneEdge) -> SplitNode {
        switch self {
        case .leaf(let id):
            guard id == target else { return self }
            let axis: SplitAxis = (edge == .left || edge == .right) ? .horizontal : .vertical
            let newFirst = edge == .left || edge == .top
            return .split(
                axis: axis, ratio: 0.5,
                first: newFirst ? .leaf(pane) : self,
                second: newFirst ? self : .leaf(pane)
            )
        case .split(let axis, let ratio, let first, let second):
            return .split(
                axis: axis, ratio: ratio,
                first: first.inserting(pane, at: target, edge: edge),
                second: second.inserting(pane, at: target, edge: edge)
            )
        }
    }

    /// Removes `pane`; its sibling takes the parent split's place. Nil when `pane` was the only leaf.
    public func removing(_ pane: PaneID) -> SplitNode? {
        switch self {
        case .leaf(let id):
            return id == pane ? nil : self
        case .split(let axis, let ratio, let first, let second):
            guard let newFirst = first.removing(pane) else { return second }
            guard let newSecond = second.removing(pane) else { return first }
            return .split(axis: axis, ratio: ratio, first: newFirst, second: newSecond)
        }
    }

    /// Sets the ratio of the split at `path` (clamped). Returns self if `path` does not name a split.
    public func resizing(at path: SplitPath, ratio newRatio: Double) -> SplitNode {
        guard case .split(let axis, let ratio, let first, let second) = self else { return self }
        guard let step = path.steps.first else {
            return .split(axis: axis, ratio: Self.clamp(newRatio), first: first, second: second)
        }
        let rest = SplitPath(steps: Array(path.steps.dropFirst()))
        return step
            ? .split(axis: axis, ratio: ratio, first: first, second: second.resizing(at: rest, ratio: newRatio))
            : .split(axis: axis, ratio: ratio, first: first.resizing(at: rest, ratio: newRatio), second: second)
    }

    public func equalized() -> SplitNode {
        switch self {
        case .leaf: return self
        case .split(let axis, _, let first, let second):
            return .split(axis: axis, ratio: 0.5, first: first.equalized(), second: second.equalized())
        }
    }

    /// Each pane's frame when the tree fills `rect`. y grows downward: `first` of a vertical split is on top.
    public func frames(in rect: CGRect) -> [PaneID: CGRect] {
        switch self {
        case .leaf(let id):
            return [id: rect]
        case .split(let axis, let ratio, let first, let second):
            let (a, b) = Self.divide(rect, axis: axis, ratio: ratio)
            return first.frames(in: a).merging(second.frames(in: b)) { lhs, _ in lhs }
        }
    }

    static func divide(_ rect: CGRect, axis: SplitAxis, ratio: Double) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let w = rect.width * ratio
            return (
                CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height)
            )
        case .vertical:
            let h = rect.height * ratio
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h),
                CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h)
            )
        }
    }

    /// The pane adjacent to `pane` in `direction`, by on-screen position: among panes whose facing
    /// edge touches `pane`'s, the one overlapping it most along the other axis; ties go to the one
    /// nearest the top-left. Nil at the tree's edge.
    public func neighbor(of pane: PaneID, direction: SplitDirection) -> PaneID? {
        let frames = frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let source = frames[pane] else { return nil }
        let epsilon = 1e-9
        var best: (id: PaneID, overlap: Double, frame: CGRect)?
        for (id, frame) in frames where id != pane {
            let touches: Bool
            let overlap: Double
            switch direction {
            case .right:
                touches = abs(frame.minX - source.maxX) < epsilon
                overlap = min(frame.maxY, source.maxY) - max(frame.minY, source.minY)
            case .left:
                touches = abs(frame.maxX - source.minX) < epsilon
                overlap = min(frame.maxY, source.maxY) - max(frame.minY, source.minY)
            case .down:
                touches = abs(frame.minY - source.maxY) < epsilon
                overlap = min(frame.maxX, source.maxX) - max(frame.minX, source.minX)
            case .up:
                touches = abs(frame.maxY - source.minY) < epsilon
                overlap = min(frame.maxX, source.maxX) - max(frame.minX, source.minX)
            }
            guard touches, overlap > epsilon else { continue }
            if let current = best {
                let better = overlap > current.overlap + epsilon
                    || (abs(overlap - current.overlap) <= epsilon
                        && (frame.minY, frame.minX) < (current.frame.minY, current.frame.minX))
                if !better { continue }
            }
            best = (id, overlap, frame)
        }
        return best?.id
    }
}
