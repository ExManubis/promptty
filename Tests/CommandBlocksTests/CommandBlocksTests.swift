import CoreGraphics
import CommandBlocks
import Testing

private func block(_ row: Int, _ end: Int, exit: Int? = 0) -> CommandBlock {
    CommandBlock(row: row, endRow: end, exitCode: exit)
}

/// 10 rows on screen, 100 rows in all; rows are 20 points tall below 4 points of padding.
private func viewport(top: Int, rows: Int = 10, total: Int = 100) -> BlockViewport {
    BlockViewport(top: top, rows: rows, totalRows: total, rowHeight: 20, paddingTop: 4)
}

private let blocks = [block(0, 30), block(31, 31, exit: 1), block(32, 60), block(61, 64, exit: nil)]

@Suite struct NavigationTests {
    @Test func previousFromNothingAtTheBottomSelectsTheNewest() {
        let snap = BlockSnapshot(blocks: blocks, viewport: viewport(top: 90))
        #expect(BlockNavigation.previous(from: nil, in: snap) == BlockSelection(fromEnd: 0))
    }

    @Test func previousFromNothingScrolledUpSelectsTheLastBlockStartingOnScreen() {
        // Rows 35–44 are on screen: inside the third block, whose command is above.
        let snap = BlockSnapshot(blocks: blocks, viewport: viewport(top: 35))
        #expect(BlockNavigation.previous(from: nil, in: snap)?.index(in: snap.blocks) == 2)
        // Rows 28–37: the second and third blocks start on screen.
        let up = BlockSnapshot(blocks: blocks, viewport: viewport(top: 28))
        #expect(BlockNavigation.previous(from: nil, in: up)?.index(in: up.blocks) == 2)
    }

    @Test func previousStopsAtTheOldest() {
        let snap = BlockSnapshot(blocks: blocks, viewport: viewport(top: 0))
        let oldest = BlockSelection(fromEnd: 3)
        #expect(BlockNavigation.previous(from: oldest, in: snap) == oldest)
        #expect(BlockNavigation.previous(from: BlockSelection(fromEnd: 1), in: snap) == BlockSelection(fromEnd: 2))
    }

    @Test func nextPastTheNewestSelectsNothing() {
        let snap = BlockSnapshot(blocks: blocks, viewport: viewport(top: 90))
        #expect(BlockNavigation.next(from: BlockSelection(fromEnd: 0), in: snap) == nil)
        #expect(BlockNavigation.next(from: BlockSelection(fromEnd: 2), in: snap) == BlockSelection(fromEnd: 1))
    }

    @Test func nextFromNothingSelectsTheFirstBlockStartingOnScreen() {
        let snap = BlockSnapshot(blocks: blocks, viewport: viewport(top: 25))
        #expect(BlockNavigation.next(from: nil, in: snap)?.index(in: snap.blocks) == 1)
        let bottom = BlockSnapshot(blocks: blocks, viewport: viewport(top: 90))
        #expect(BlockNavigation.next(from: nil, in: bottom) == nil)
    }

    @Test func noBlocksNoSelection() {
        let snap = BlockSnapshot(blocks: [], viewport: viewport(top: 0))
        #expect(BlockNavigation.previous(from: nil, in: snap) == nil)
        #expect(BlockNavigation.next(from: nil, in: snap) == nil)
        #expect(BlockSelection(fromEnd: 0).index(in: []) == nil)
    }

    @Test func aSelectionPastTheOldestIsGone() {
        #expect(BlockSelection(fromEnd: 4).index(in: blocks) == nil)
        #expect(BlockSelection(fromEnd: 0).index(in: blocks) == 3)
    }
}

@Suite struct ScrollTests {
    @Test func aBlockOnScreenNeedsNoScroll() {
        #expect(BlockNavigation.scrollTarget(for: block(32, 36), in: viewport(top: 30)) == nil)
    }

    @Test func aBlockAboveIsShownFromItsCommand() {
        // At the top, so no other command's header covers it.
        #expect(BlockNavigation.scrollTarget(for: block(20, 22), in: viewport(top: 30)) == 20)
        #expect(BlockNavigation.scrollTarget(for: block(0, 2), in: viewport(top: 30)) == 0)
    }

    @Test func aBlockBelowIsShownToItsLastRowWithARowBelow() {
        #expect(BlockNavigation.scrollTarget(for: block(45, 48), in: viewport(top: 30)) == 40)
        // Never past the bottom.
        #expect(BlockNavigation.scrollTarget(for: block(95, 99), in: viewport(top: 30)) == 90)
    }

    @Test func aTallBlockIsShownFromItsCommand() {
        #expect(BlockNavigation.scrollTarget(for: block(32, 60), in: viewport(top: 40)) == 32)
        #expect(BlockNavigation.scrollTarget(for: block(32, 60), in: viewport(top: 32)) == nil)
    }
}

@Suite struct LayoutTests {
    @Test func rowsBecomePointsBelowThePadding() {
        let v = viewport(top: 30)
        #expect(v.y(ofRow: 30) == 4)
        #expect(v.y(ofRow: 32) == 44)
        #expect(v.y(ofRow: 29) == -16)
    }

    @Test func visibleBlocksAreThoseOverlappingTheViewport() {
        let snap = BlockSnapshot(blocks: blocks, viewport: viewport(top: 30))
        let frames = BlockLayout.visible(snap)
        #expect(frames.map(\.index) == [0, 1, 2])
        // The first ends on row 30: its last row is the top row on screen.
        #expect(frames[0].minY == -596 && frames[0].maxY == 24)
        #expect(frames[1].minY == 24 && frames[1].maxY == 44)
    }

    @Test func theStickyBlockIsTheOneWhoseCommandScrolledOff() {
        // Scrolled up into the third block's output.
        #expect(BlockLayout.sticky(BlockSnapshot(blocks: blocks, viewport: viewport(top: 40))) == 2)
        // Its command is the top row: nothing to remind.
        #expect(BlockLayout.sticky(BlockSnapshot(blocks: blocks, viewport: viewport(top: 32))) == nil)
        // At the bottom the live output is what matters; no header.
        #expect(BlockLayout.sticky(BlockSnapshot(blocks: blocks, viewport: viewport(top: 90, total: 100))) == nil)
        // Between blocks (rows past the last block's end).
        #expect(BlockLayout.sticky(BlockSnapshot(blocks: blocks, viewport: viewport(top: 70))) == nil)
    }

    @Test func dividersSitInTheGapBetweenBlocks() {
        // Blank row 2 between the blocks (44–64 points): the line runs through its middle.
        let spaced = BlockSnapshot(blocks: [block(0, 1), block(3, 4)], viewport: viewport(top: 0))
        #expect(BlockLayout.dividerY(before: 1, in: spaced) == CGFloat(54))
        // No gap: on the command's top edge. None above the first block.
        let tight = BlockSnapshot(blocks: [block(0, 1), block(2, 4)], viewport: viewport(top: 0))
        #expect(BlockLayout.dividerY(before: 1, in: tight) == CGFloat(44))
        #expect(BlockLayout.dividerY(before: 0, in: tight) == nil)
    }

    @Test func atBottom() {
        #expect(viewport(top: 90).atBottom)
        #expect(!viewport(top: 89).atBottom)
    }
}
