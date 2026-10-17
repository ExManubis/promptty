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
        #expect(BlockNavigation.previous(from: nil, in: snap)?.index(in: snap) == 2)
        // Rows 28–37: the second and third blocks start on screen.
        let up = BlockSnapshot(blocks: blocks, viewport: viewport(top: 28))
        #expect(BlockNavigation.previous(from: nil, in: up)?.index(in: up) == 2)
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
        #expect(BlockNavigation.next(from: nil, in: snap)?.index(in: snap) == 1)
        let bottom = BlockSnapshot(blocks: blocks, viewport: viewport(top: 90))
        #expect(BlockNavigation.next(from: nil, in: bottom) == nil)
    }

    @Test func noBlocksNoSelection() {
        let snap = BlockSnapshot(blocks: [], viewport: viewport(top: 0))
        #expect(BlockNavigation.previous(from: nil, in: snap) == nil)
        #expect(BlockNavigation.next(from: nil, in: snap) == nil)
        #expect(BlockSelection(fromEnd: 0).index(in: snap) == nil)
        #expect(!snap.hasBlocks)
    }

    @Test func aSelectionPastTheOldestIsGone() {
        let snap = BlockSnapshot(blocks: blocks, viewport: viewport(top: 90))
        #expect(BlockSelection(fromEnd: 4).index(in: snap) == nil)
        #expect(BlockSelection(fromEnd: 0).index(in: snap) == 3)
    }

    @Test func aBlockKeepsItsCountFromTheEndInASnapshotOfTheScreen() {
        // The second and third blocks, around rows 31–40; the fourth starts below the screen.
        let all = BlockSnapshot(blocks: blocks, viewport: viewport(top: 31))
        let screen = BlockSnapshot(blocks: Array(blocks[1...2]), viewport: viewport(top: 31), newer: 1)
        #expect(screen.hasBlocks)
        for index in 1...2 {
            let block = BlockSelection(index: index, in: all)
            #expect(BlockSelection(index: index - 1, in: screen) == block)
            #expect(block.index(in: screen) == index - 1)
        }
        // The newest and the oldest are not in it.
        #expect(BlockSelection(fromEnd: 0).index(in: screen) == nil)
        #expect(BlockSelection(fromEnd: 3).index(in: screen) == nil)
        // Only blocks below the screen: still blocks.
        #expect(BlockSnapshot(blocks: [], viewport: viewport(top: 0), newer: 2).hasBlocks)
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

@Suite struct FailedNavigationTests {
    // Blocks 1 and 4 failed; the last one is still running.
    private let list = [block(0, 10), block(11, 20, exit: 1), block(21, 30), block(31, 40, exit: 2), block(41, 50), block(51, 55, exit: nil)]

    @Test func previousFailedSkipsTheOnesThatSucceeded() {
        let snap = BlockSnapshot(blocks: list, viewport: viewport(top: 90))
        let from = BlockSelection(fromEnd: 0)
        let first = BlockNavigation.previousFailed(from: from, in: snap)
        #expect(first?.index(in: snap) == 3)
        #expect(BlockNavigation.previousFailed(from: first, in: snap)?.index(in: snap) == 1)
    }

    @Test func previousFailedWithNoOlderOneIsNil() {
        let snap = BlockSnapshot(blocks: list, viewport: viewport(top: 90))
        #expect(BlockNavigation.previousFailed(from: BlockSelection(index: 1, in: snap), in: snap) == nil)
    }

    @Test func previousFailedFromNothingStartsAtTheScreen() {
        // Rows 25–34 on screen: block 3 starts there, so it is the last that starts on screen.
        let snap = BlockSnapshot(blocks: list, viewport: viewport(top: 25))
        #expect(BlockNavigation.previousFailed(from: nil, in: snap)?.index(in: snap) == 3)
        // Rows 12–21: blocks up to 2 start on screen; the failed one is block 1.
        let up = BlockSnapshot(blocks: list, viewport: viewport(top: 12))
        #expect(BlockNavigation.previousFailed(from: nil, in: up)?.index(in: up) == 1)
    }

    @Test func nextFailedSkipsTheOnesThatSucceeded() {
        let snap = BlockSnapshot(blocks: list, viewport: viewport(top: 0))
        let first = BlockNavigation.nextFailed(from: BlockSelection(index: 0, in: snap), in: snap)
        #expect(first?.index(in: snap) == 1)
        #expect(BlockNavigation.nextFailed(from: first, in: snap)?.index(in: snap) == 3)
        #expect(BlockNavigation.nextFailed(from: BlockSelection(index: 3, in: snap), in: snap) == nil)
    }

    @Test func nextFailedFromNothingStartsAtTheScreen() {
        let snap = BlockSnapshot(blocks: list, viewport: viewport(top: 25))
        #expect(BlockNavigation.nextFailed(from: nil, in: snap)?.index(in: snap) == 3)
        let bottom = BlockSnapshot(blocks: list, viewport: viewport(top: 90))
        #expect(BlockNavigation.nextFailed(from: nil, in: bottom) == nil)
    }

    @Test func noFailuresNoSelection() {
        let snap = BlockSnapshot(blocks: [block(0, 3), block(4, 6, exit: nil)], viewport: viewport(top: 0))
        #expect(BlockNavigation.previousFailed(from: nil, in: snap) == nil)
        #expect(BlockNavigation.nextFailed(from: nil, in: snap) == nil)
    }

    @Test func worksWithASnapshotOfOnlyTheNewestBlocks() {
        // Counted from the end, with older blocks left out and newer ones not listed.
        let snap = BlockSnapshot(blocks: Array(list[1...3]), viewport: viewport(top: 0), newer: 2)
        let from = BlockSelection(fromEnd: 2)   // block 3 of the list
        #expect(BlockNavigation.previousFailed(from: from, in: snap)?.fromEnd == 4)
    }
}

@Suite struct MarkdownTests {
    @Test func commandAndOutputInAConsoleFence() {
        #expect(BlockMarkdown.format(command: "ls -l", output: "a\nb") == "```console\n$ ls -l\na\nb\n```")
    }

    @Test func noOutputIsJustTheCommand() {
        #expect(BlockMarkdown.format(command: "true", output: "") == "```console\n$ true\n```")
        #expect(BlockMarkdown.format(command: "true", output: "\n\n") == "```console\n$ true\n```")
    }

    @Test func trailingNewlinesAreDropped() {
        #expect(BlockMarkdown.format(command: "echo hi", output: "hi\n") == "```console\n$ echo hi\nhi\n```")
    }

    @Test func aFenceInTheOutputGetsALongerOne() {
        let md = BlockMarkdown.format(command: "cat x.md", output: "```swift\nlet a = 1\n```")
        #expect(md == "````console\n$ cat x.md\n```swift\nlet a = 1\n```\n````")
    }

    @Test func aMultiLineCommandContinuesWithAnArrow() {
        #expect(BlockMarkdown.format(command: "echo a \\\n  b", output: "a b") == "```console\n$ echo a \\\n>   b\na b\n```")
    }
}

private func scrolled(top: Int, total: Int) -> BlockViewport {
    BlockViewport(top: top, rows: 10, totalRows: total, rowHeight: 16, paddingTop: 0)
}

@Test func newOutputCountsLinesAddedWhileScrolledBack() {
    var t = NewOutputTracker()
    #expect(t.update(scrolled(top: 90, total: 100)) == nil)   // at the bottom
    #expect(t.update(scrolled(top: 50, total: 100)) == nil)   // scrolled back, nothing new
    #expect(t.update(scrolled(top: 50, total: 112)) == 12)
    #expect(t.update(scrolled(top: 50, total: 130)) == 30)
    #expect(t.update(scrolled(top: 120, total: 130)) == nil)  // back at the bottom
    #expect(t.update(scrolled(top: 100, total: 130)) == nil)  // away again: counting starts over
    #expect(t.update(scrolled(top: 100, total: 131)) == 1)
}

@Test func newOutputStartsOverAfterAClear() {
    var t = NewOutputTracker()
    _ = t.update(scrolled(top: 90, total: 100))
    _ = t.update(scrolled(top: 50, total: 100))
    #expect(t.update(scrolled(top: 0, total: 40)) == nil)
    #expect(t.update(scrolled(top: 0, total: 45)) == 5)
}
