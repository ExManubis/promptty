import CoreGraphics
import XCTest
@testable import WorkspaceModel

final class SplitNodeTests: XCTestCase {
    private let a = PaneID(), b = PaneID(), c = PaneID(), d = PaneID()

    // MARK: Splitting

    func testSplitRightPutsNewPaneSecondSideBySide() {
        let tree = SplitNode.leaf(a).splitting(a, direction: .right, newPane: b)
        XCTAssertEqual(tree, .split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b)))
    }

    func testSplitLeftPutsNewPaneFirst() {
        let tree = SplitNode.leaf(a).splitting(a, direction: .left, newPane: b)
        XCTAssertEqual(tree, .split(axis: .horizontal, ratio: 0.5, first: .leaf(b), second: .leaf(a)))
    }

    func testSplitDownStacksNewPaneSecond() {
        let tree = SplitNode.leaf(a).splitting(a, direction: .down, newPane: b)
        XCTAssertEqual(tree, .split(axis: .vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b)))
    }

    func testSplitUpStacksNewPaneFirst() {
        let tree = SplitNode.leaf(a).splitting(a, direction: .up, newPane: b)
        XCTAssertEqual(tree, .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(a)))
    }

    func testSplitNestedLeafLeavesSiblingsAlone() {
        let tree = SplitNode.split(axis: .horizontal, ratio: 0.3, first: .leaf(a), second: .leaf(b))
            .splitting(b, direction: .down, newPane: c)
        XCTAssertEqual(tree, .split(
            axis: .horizontal, ratio: 0.3, first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        ))
    }

    func testSplittingUnknownPaneReturnsTreeUnchanged() {
        let tree = SplitNode.leaf(a)
        XCTAssertEqual(tree.splitting(b, direction: .right, newPane: c), tree)
    }

    // MARK: Removing

    func testRemovingOnlyLeafReturnsNil() {
        XCTAssertNil(SplitNode.leaf(a).removing(a))
    }

    func testRemovingLeafPromotesSibling() {
        let tree = SplitNode.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        XCTAssertEqual(tree.removing(a), .leaf(b))
        XCTAssertEqual(tree.removing(b), .leaf(a))
    }

    func testRemovingFromNestedTreeKeepsOtherRatios() {
        let tree = SplitNode.split(
            axis: .horizontal, ratio: 0.3, first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.7, first: .leaf(b), second: .leaf(c))
        )
        XCTAssertEqual(tree.removing(c), .split(axis: .horizontal, ratio: 0.3, first: .leaf(a), second: .leaf(b)))
        XCTAssertEqual(tree.removing(a), .split(axis: .vertical, ratio: 0.7, first: .leaf(b), second: .leaf(c)))
    }

    func testRemovingUnknownPaneReturnsTreeUnchanged() {
        let tree = SplitNode.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        XCTAssertEqual(tree.removing(c), tree)
    }

    // MARK: Inserting

    func testInsertingOnEachEdge() {
        let base = SplitNode.leaf(a)
        XCTAssertEqual(base.inserting(b, at: a, edge: .left), .split(axis: .horizontal, ratio: 0.5, first: .leaf(b), second: .leaf(a)))
        XCTAssertEqual(base.inserting(b, at: a, edge: .right), .split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b)))
        XCTAssertEqual(base.inserting(b, at: a, edge: .top), .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(a)))
        XCTAssertEqual(base.inserting(b, at: a, edge: .bottom), .split(axis: .vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b)))
    }

    // MARK: Ratios

    func testResizingClampsRatio() {
        let tree = SplitNode.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        XCTAssertEqual(tree.resizing(at: SplitPath(steps: []), ratio: 0.0), .split(axis: .horizontal, ratio: 0.1, first: .leaf(a), second: .leaf(b)))
        XCTAssertEqual(tree.resizing(at: SplitPath(steps: []), ratio: 1.0), .split(axis: .horizontal, ratio: 0.9, first: .leaf(a), second: .leaf(b)))
        XCTAssertEqual(tree.resizing(at: SplitPath(steps: []), ratio: 0.25), .split(axis: .horizontal, ratio: 0.25, first: .leaf(a), second: .leaf(b)))
    }

    func testResizingNestedSplitByPath() {
        let tree = SplitNode.split(
            axis: .horizontal, ratio: 0.5, first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        let resized = tree.resizing(at: SplitPath(steps: [true]), ratio: 0.8)
        XCTAssertEqual(resized, .split(
            axis: .horizontal, ratio: 0.5, first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.8, first: .leaf(b), second: .leaf(c))
        ))
    }

    func testResizingInvalidPathReturnsTreeUnchanged() {
        let tree = SplitNode.leaf(a)
        XCTAssertEqual(tree.resizing(at: SplitPath(steps: [true]), ratio: 0.3), tree)
    }

    func testEqualizedSetsEveryRatioToHalf() {
        let tree = SplitNode.split(
            axis: .horizontal, ratio: 0.2, first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.9, first: .leaf(b), second: .leaf(c))
        )
        XCTAssertEqual(tree.equalized(), .split(
            axis: .horizontal, ratio: 0.5, first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        ))
    }

    // MARK: Reading

    func testLeavesInReadingOrder() {
        let tree = SplitNode.split(
            axis: .horizontal, ratio: 0.5,
            first: .split(axis: .vertical, ratio: 0.5, first: .leaf(a), second: .leaf(c)),
            second: .leaf(b)
        )
        XCTAssertEqual(tree.leaves, [a, c, b])
        XCTAssertTrue(tree.contains(c))
        XCTAssertFalse(tree.contains(d))
    }

    func testFramesTileTheRect() {
        let tree = SplitNode.split(
            axis: .horizontal, ratio: 0.25, first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 400, height: 200))
        XCTAssertEqual(frames[a], CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(frames[b], CGRect(x: 100, y: 0, width: 300, height: 100))
        XCTAssertEqual(frames[c], CGRect(x: 100, y: 100, width: 300, height: 100))
    }

    // MARK: Neighbors

    /// a | b
    /// --+--
    /// c | d
    private var grid: SplitNode {
        .split(
            axis: .horizontal, ratio: 0.5,
            first: .split(axis: .vertical, ratio: 0.5, first: .leaf(a), second: .leaf(c)),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(d))
        )
    }

    func testNeighborInGrid() {
        XCTAssertEqual(grid.neighbor(of: a, direction: .right), b)
        XCTAssertEqual(grid.neighbor(of: a, direction: .down), c)
        XCTAssertEqual(grid.neighbor(of: b, direction: .down), d)
        XCTAssertEqual(grid.neighbor(of: d, direction: .left), c)
        XCTAssertEqual(grid.neighbor(of: d, direction: .up), b)
    }

    func testNeighborAtEdgeIsNil() {
        XCTAssertNil(grid.neighbor(of: a, direction: .left))
        XCTAssertNil(grid.neighbor(of: a, direction: .up))
        XCTAssertNil(grid.neighbor(of: d, direction: .right))
        XCTAssertNil(grid.neighbor(of: d, direction: .down))
    }

    func testNeighborPrefersMostOverlap() {
        // a spans the full left; on the right b is the top 30%, c the bottom 70%.
        let tree = SplitNode.split(
            axis: .horizontal, ratio: 0.5, first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.3, first: .leaf(b), second: .leaf(c))
        )
        XCTAssertEqual(tree.neighbor(of: a, direction: .right), c)
        XCTAssertEqual(tree.neighbor(of: b, direction: .left), a)
        XCTAssertEqual(tree.neighbor(of: c, direction: .up), b)
    }

    func testNeighborTieGoesToTopLeftMost() {
        // a on the left; b and c split the right side evenly: both overlap a by half.
        let tree = SplitNode.split(
            axis: .horizontal, ratio: 0.5, first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        XCTAssertEqual(tree.neighbor(of: a, direction: .right), b)
    }
}
