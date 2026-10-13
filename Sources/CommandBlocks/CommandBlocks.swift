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

/// Blocks of one terminal, oldest first, and where its screen is: all of them (the newest that fit),
/// or those on screen and the one before them, with `newer` counting those below the screen.
public struct BlockSnapshot: Equatable, Sendable {
    public var blocks: [CommandBlock]
    public var viewport: BlockViewport
    /// Blocks after the last in `blocks`.
    public var newer: Int

    public init(blocks: [CommandBlock], viewport: BlockViewport, newer: Int = 0) {
        self.blocks = blocks
        self.viewport = viewport
        self.newer = newer
    }

    /// Whether the terminal has any block, listed here or not.
    public var hasBlocks: Bool { !blocks.isEmpty || newer > 0 }
}

/// A block, counted from the newest (0). Old blocks drop off the top of the scrollback and their
/// rows shift; counted from the end, it stays on the same command until a new one runs (which
/// clears a selection), and it stays put in a snapshot of another part of the screen.
public struct BlockSelection: Equatable, Sendable {
    public var fromEnd: Int

    public init(fromEnd: Int) { self.fromEnd = fromEnd }

    /// The block at `index` in `snapshot.blocks`.
    public init(index: Int, in snapshot: BlockSnapshot) {
        fromEnd = snapshot.blocks.count - 1 - index + snapshot.newer
    }

    /// Its index in `snapshot.blocks`, or nil when it is not there.
    public func index(in snapshot: BlockSnapshot) -> Int? {
        let index = snapshot.blocks.count - 1 - (fromEnd - snapshot.newer)
        return snapshot.blocks.indices.contains(index) ? index : nil
    }
}

/// Moving the selection between blocks (⌘↑ and ⌘↓) and bringing the selected one into view, in a
/// snapshot of all blocks.
public enum BlockNavigation {
    /// The block above: with nothing selected, the last block that starts on or above the screen.
    /// The oldest stays selected.
    public static func previous(from selection: BlockSelection?, in snapshot: BlockSnapshot) -> BlockSelection? {
        let blocks = snapshot.blocks
        guard !blocks.isEmpty else { return nil }
        if let current = selection?.index(in: snapshot) {
            return BlockSelection(index: max(0, current - 1), in: snapshot)
        }
        let screenEnd = snapshot.viewport.top + snapshot.viewport.rows
        guard let index = blocks.lastIndex(where: { $0.row < screenEnd }) else { return nil }
        return BlockSelection(index: index, in: snapshot)
    }

    /// The block below: with nothing selected, the first block that starts on or below the top of
    /// the screen. Past the newest, nothing is selected.
    public static func next(from selection: BlockSelection?, in snapshot: BlockSnapshot) -> BlockSelection? {
        let blocks = snapshot.blocks
        if let current = selection?.index(in: snapshot) {
            return current + 1 < blocks.count ? BlockSelection(index: current + 1, in: snapshot) : nil
        }
        guard let index = blocks.firstIndex(where: { $0.row >= snapshot.viewport.top }) else { return nil }
        return BlockSelection(index: index, in: snapshot)
    }

    /// The failed block above: from the selection, or with nothing selected from the last block
    /// that starts on or above the screen. Nil when there is none.
    public static func previousFailed(from selection: BlockSelection?, in snapshot: BlockSnapshot) -> BlockSelection? {
        let blocks = snapshot.blocks
        let before: Int
        if let current = selection?.index(in: snapshot) {
            before = current
        } else {
            let screenEnd = snapshot.viewport.top + snapshot.viewport.rows
            before = (blocks.lastIndex(where: { $0.row < screenEnd }) ?? -1) + 1
        }
        guard let index = blocks[..<max(0, before)].lastIndex(where: \.failed) else { return nil }
        return BlockSelection(index: index, in: snapshot)
    }

    /// The failed block below: from the selection, or with nothing selected from the first block
    /// that starts on or below the top of the screen. Nil when there is none.
    public static func nextFailed(from selection: BlockSelection?, in snapshot: BlockSnapshot) -> BlockSelection? {
        let blocks = snapshot.blocks
        let from: Int
        if let current = selection?.index(in: snapshot) {
            from = current + 1
        } else {
            from = blocks.firstIndex(where: { $0.row >= snapshot.viewport.top }) ?? blocks.count
        }
        guard from < blocks.count, let index = blocks[from...].firstIndex(where: \.failed) else { return nil }
        return BlockSelection(index: index, in: snapshot)
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

    /// Where the line above block `index` goes: through the middle of the blank row before its
    /// command when there is one, else along the command's top edge. None above the first.
    public static func dividerY(before index: Int, in snapshot: BlockSnapshot) -> CGFloat? {
        guard index > 0, snapshot.blocks.indices.contains(index) else { return nil }
        let block = snapshot.blocks[index]
        let gap = block.row - snapshot.blocks[index - 1].endRow - 1
        let v = snapshot.viewport
        return v.y(ofRow: block.row) - (gap > 0 ? v.rowHeight / 2 : 0)
    }

    /// The block with a row at `y` points from the view's top edge.
    public static func block(atY y: CGFloat, in snapshot: BlockSnapshot) -> Int? {
        let row = snapshot.viewport.row(atY: y)
        return snapshot.blocks.firstIndex { $0.row <= row && row <= $0.endRow }
    }
}

/// A block as Markdown, to paste into an issue or a chat.
public enum BlockMarkdown {
    /// The command after a `$` and its output, in a fenced `console` block. A command that spans
    /// lines continues with `>`; the fence is longer than any run of backticks in the text.
    public static func format(command: String, output: String) -> String {
        var lines = command.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { i, line in
            (i == 0 ? "$ " : "> ") + line
        }
        var body = output
        while body.hasSuffix("\n") { body.removeLast() }
        if !body.isEmpty { lines.append(body) }
        var longest = 0, run = 0
        for ch in lines.joined(separator: "\n") {
            run = ch == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)console\n\(lines.joined(separator: "\n"))\n\(fence)"
    }
}
