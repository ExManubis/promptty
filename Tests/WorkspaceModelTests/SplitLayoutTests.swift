import CoreGraphics
import XCTest
@testable import WorkspaceModel

final class SplitLayoutTests: XCTestCase {
    private let a = PaneID(), b = PaneID(), c = PaneID()
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testSingleLeafFillsTheArea() {
        let layout = SplitNode.leaf(a).layout(in: area, gap: 8)
        XCTAssertEqual(layout.panes, [a: area])
        XCTAssertTrue(layout.dividers.isEmpty)
    }

    func testHorizontalSplitLeavesAGapBetweenItsSides() {
        let tree = SplitNode.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let layout = tree.layout(in: area, gap: 8)
        XCTAssertEqual(layout.panes[a], CGRect(x: 0, y: 0, width: 496, height: 600))
        XCTAssertEqual(layout.panes[b], CGRect(x: 504, y: 0, width: 496, height: 600))
        XCTAssertEqual(layout.dividers, [SplitLayout.Divider(
            path: SplitPath(steps: []), axis: .horizontal, ratio: 0.5, available: 992,
            frame: CGRect(x: 496, y: 0, width: 8, height: 600)
        )])
    }

    func testVerticalSplitPutsFirstOnTop() {
        let tree = SplitNode.split(axis: .vertical, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let layout = tree.layout(in: area, gap: 8)
        XCTAssertEqual(layout.panes[a], CGRect(x: 0, y: 0, width: 1000, height: 296))
        XCTAssertEqual(layout.panes[b], CGRect(x: 0, y: 304, width: 1000, height: 296))
    }

    func testFirstSideIsRoundedToWholePoints() {
        let tree = SplitNode.split(axis: .horizontal, ratio: 0.3, first: .leaf(a), second: .leaf(b))
        let layout = tree.layout(in: area, gap: 8)
        XCTAssertEqual(layout.panes[a]?.width, 298) // 992 × 0.3 = 297.6
        XCTAssertEqual(layout.panes[b], CGRect(x: 306, y: 0, width: 694, height: 600))
    }

    func testNestedSplitsAreAddressedLikeResizing() {
        let tree = SplitNode.split(
            axis: .horizontal, ratio: 0.5, first: .leaf(a),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
        )
        let layout = tree.layout(in: area, gap: 8)
        XCTAssertEqual(layout.panes[b], CGRect(x: 504, y: 0, width: 496, height: 296))
        XCTAssertEqual(layout.panes[c], CGRect(x: 504, y: 304, width: 496, height: 296))
        XCTAssertEqual(layout.dividers.map(\.path), [SplitPath(steps: []), SplitPath(steps: [true])])
        XCTAssertEqual(layout.dividers[1].frame, CGRect(x: 504, y: 296, width: 496, height: 8))
    }

    func testOffsetAreaOffsetsEveryFrame() {
        let tree = SplitNode.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let layout = tree.layout(in: CGRect(x: 10, y: 20, width: 1000, height: 600), gap: 8)
        XCTAssertEqual(layout.panes[b], CGRect(x: 514, y: 20, width: 496, height: 600))
    }

    func testAreaSmallerThanTheGapNeverGivesNegativeSizes() {
        let tree = SplitNode.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let layout = tree.layout(in: CGRect(x: 0, y: 0, width: 4, height: 10), gap: 8)
        for frame in layout.panes.values {
            XCTAssertGreaterThanOrEqual(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.height, 0)
        }
    }
}
