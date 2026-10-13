import CoreGraphics

/// A command the shell ran and the output it printed, as the terminal found it from the shell
/// integration's marks. Rows count from the top of the scrollback.
public struct CommandBlock: Equatable, Sendable {
    /// The row the command is on.
    public var row: Int
    /// The last row with text, at least `row`.
    public var endRow: Int
    /// Nil while the command runs, or when the shell did not report it.
    public var exitCode: Int?

    public init(row: Int, endRow: Int, exitCode: Int?) {
        self.row = row
        self.endRow = endRow
        self.exitCode = exitCode
    }

    public var failed: Bool { (exitCode ?? 0) != 0 }
}

/// Which rows of the scrollback are on screen, and how tall a row is.
public struct BlockViewport: Equatable, Sendable {
    /// The row at the top of the screen.
    public var top: Int
    public var rows: Int
    /// Rows in the scrollback and on screen together.
    public var totalRows: Int
    /// Points.
    public var rowHeight: CGFloat
    /// Points between the view's top edge and the first row.
    public var paddingTop: CGFloat

    public init(top: Int, rows: Int, totalRows: Int, rowHeight: CGFloat, paddingTop: CGFloat) {
        self.top = top
        self.rows = rows
        self.totalRows = totalRows
        self.rowHeight = rowHeight
        self.paddingTop = paddingTop
    }

    /// Showing the newest output.
    public var atBottom: Bool { top + rows >= totalRows }

    /// The highest top row there is.
    var lastTop: Int { max(0, totalRows - rows) }

    /// The top edge of `row`, in points from the view's top edge (negative above the screen).
    public func y(ofRow row: Int) -> CGFloat {
        paddingTop + CGFloat(row - top) * rowHeight
    }

    /// The scrollback row under a point `y` points from the view's top edge.
    public func row(atY y: CGFloat) -> Int {
        top + Int(((y - paddingTop) / rowHeight).rounded(.down))
    }
}

/// The blocks of one terminal, oldest first, and where its screen is.
public struct BlockSnapshot: Equatable, Sendable {
    public var blocks: [CommandBlock]
    public var viewport: BlockViewport

    public init(blocks: [CommandBlock], viewport: BlockViewport) {
        self.blocks = blocks
        self.viewport = viewport
    }
}

/// A selected block, counted from the newest (0). Old blocks drop off the top of the scrollback
/// and their rows shift; counted from the end, the selection stays on the same command until a
/// new one runs (which clears it).
public struct BlockSelection: Equatable, Sendable {
    public var fromEnd: Int

    public init(fromEnd: Int) { self.fromEnd = fromEnd }

    init(index: Int, count: Int) { fromEnd = count - 1 - index }

    /// Its index in `blocks`, or nil when it is no longer there.
    public func index(in blocks: [CommandBlock]) -> Int? {
        let index = blocks.count - 1 - fromEnd
        return blocks.indices.contains(index) ? index : nil
    }
}

/// Moving the selection between blocks (⌘↑ and ⌘↓) and bringing the selected one into view.
public enum BlockNavigation {
    /// The block above: with nothing selected, the last block that starts on or above the screen.
    /// The oldest stays selected.
    public static func previous(from selection: BlockSelection?, in snapshot: BlockSnapshot) -> BlockSelection? {
        let blocks = snapshot.blocks
        guard !blocks.isEmpty else { return nil }
        if let current = selection?.index(in: blocks) {
            return BlockSelection(index: max(0, current - 1), count: blocks.count)
        }
        let screenEnd = snapshot.viewport.top + snapshot.viewport.rows
        guard let index = blocks.lastIndex(where: { $0.row < screenEnd }) else { return nil }
        return BlockSelection(index: index, count: blocks.count)
    }

    /// The block below: with nothing selected, the first block that starts on or below the top of
    /// the screen. Past the newest, nothing is selected.
    public static func next(from selection: BlockSelection?, in snapshot: BlockSnapshot) -> BlockSelection? {
        let blocks = snapshot.blocks
        if let current = selection?.index(in: blocks) {
            return current + 1 < blocks.count ? BlockSelection(index: current + 1, count: blocks.count) : nil
        }
        guard let index = blocks.firstIndex(where: { $0.row >= snapshot.viewport.top }) else { return nil }
        return BlockSelection(index: index, count: blocks.count)
    }

    /// The top row that brings `block` into view, or nil when it already is. Coming from below,
    /// or too tall to fit, a block is shown from its command at the top (where no other command's
    /// header covers it); coming from above, to its last row with a row of what follows.
    public static func scrollTarget(for block: CommandBlock, in viewport: BlockViewport) -> Int? {
        let height = block.endRow - block.row + 1
        let screenEnd = viewport.top + viewport.rows
        let target: Int
        if height <= viewport.rows {
            if block.row < viewport.top {
                target = block.row
            } else if block.endRow >= screenEnd {
                target = block.endRow - viewport.rows + 1 + (height < viewport.rows ? 1 : 0)
            } else {
                return nil
            }
        } else {
            target = block.row
        }
        let clamped = min(max(0, target), viewport.lastTop)
        return clamped == viewport.top ? nil : clamped
    }
}

/// Where blocks are on screen.
public enum BlockLayout {
    public struct Frame: Equatable, Sendable {
        public var index: Int
        /// Points from the view's top edge: the command row's top and the last row's bottom.
        public var minY: CGFloat
        public var maxY: CGFloat
    }

    /// The blocks with any row on screen.
    public static func visible(_ snapshot: BlockSnapshot) -> [Frame] {
        let v = snapshot.viewport
        let screenEnd = v.top + v.rows
        return snapshot.blocks.indices.compactMap { i in
            let b = snapshot.blocks[i]
            guard b.endRow >= v.top, b.row < screenEnd else { return nil }
            return Frame(index: i, minY: v.y(ofRow: b.row), maxY: v.y(ofRow: b.endRow + 1))
        }
    }

    /// The block whose output fills the top of the screen while its command has scrolled off, when
    /// scrolled back from the newest output.
    public static func sticky(_ snapshot: BlockSnapshot) -> Int? {
        let v = snapshot.viewport
        guard !v.atBottom else { return nil }
        return snapshot.blocks.lastIndex { $0.row < v.top && $0.endRow >= v.top }
    }

    /// The block with a row at `y` points from the view's top edge.
    public static func block(atY y: CGFloat, in snapshot: BlockSnapshot) -> Int? {
        let row = snapshot.viewport.row(atY: y)
        return snapshot.blocks.firstIndex { $0.row <= row && row <= $0.endRow }
    }
}
