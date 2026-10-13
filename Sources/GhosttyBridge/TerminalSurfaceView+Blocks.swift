import AppKit
import CommandBlocks
import GhosttyKit

/// Which text of a block to read.
public enum BlockPart: Sendable {
    case command, output, all
}

/// Which blocks to read.
public enum BlockRange: Sendable {
    /// The newest (up to 256): for moving between them and copying.
    case all
    /// Those on screen and the one before them, without walking the scrollback above: for drawing.
    case viewport
}

extension TerminalSurfaceView {
    /// Read into on every refresh of every pane's blocks, on the main thread.
    private static var blockBuffer = [ghostty_block_s](repeating: ghostty_block_s(), count: 256)

    /// Blocks on the screen (with the shell's marks; none in a program's full-screen mode) and
    /// where the screen is in the scrollback, or nil before the surface exists.
    public func blockSnapshot(_ range: BlockRange) -> BlockSnapshot? {
        guard let surface else { return nil }
        var info = ghostty_blocks_info_s()
        let cRange: ghostty_blocks_range_e = range == .all ? GHOSTTY_BLOCKS_ALL : GHOSTTY_BLOCKS_VIEWPORT
        let count = Self.blockBuffer.withUnsafeMutableBufferPointer { buf in
            ghostty_surface_blocks(surface, cRange, &info, buf.baseAddress, buf.count)
        }
        let scale = window?.backingScaleFactor ?? 2
        let viewport = BlockViewport(
            top: Int(info.viewport_top),
            rows: Int(info.viewport_rows),
            totalRows: Int(info.total_rows),
            rowHeight: CGFloat(info.cell_height_px) / scale,
            paddingTop: CGFloat(info.padding_top_px) / scale
        )
        let blocks = Self.blockBuffer.prefix(Int(count)).map {
            CommandBlock(row: Int($0.row), endRow: Int($0.end_row), exitCode: $0.exit_code < 0 ? nil : Int($0.exit_code))
        }
        return BlockSnapshot(blocks: blocks, viewport: viewport, newer: Int(info.newer_blocks))
    }

    /// Part of the block whose command is on `row`, without trailing blank space; nil when no
    /// block starts there or the part is empty.
    public func blockText(row: Int, part: BlockPart) -> String? {
        guard let surface, row >= 0 else { return nil }
        let cPart: ghostty_block_part_e = switch part {
        case .command: GHOSTTY_BLOCK_PART_COMMAND
        case .output: GHOSTTY_BLOCK_PART_OUTPUT
        case .all: GHOSTTY_BLOCK_PART_ALL
        }
        var text = ghostty_text_s()
        guard ghostty_surface_block_text(surface, UInt32(row), cPart, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Scrolls so that scrollback row `row` is at the top of the screen.
    public func scroll(toRow row: Int) {
        _ = performBindingAction("scroll_to_row:\(max(0, row))")
    }

    /// Scrolls to the newest output.
    public func scrollToBottom() {
        _ = performBindingAction("scroll_to_bottom")
    }
}
