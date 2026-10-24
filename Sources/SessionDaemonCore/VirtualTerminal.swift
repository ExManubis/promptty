import Foundation
import GhosttyVt

/// A pane's terminal as the daemon keeps it (libghostty-vt, no screen): every byte the program
/// writes goes through it, so when the app comes back its surface is rebuilt from a snapshot of
/// this one. It never answers the program's queries; the app's surface does.
final class VirtualTerminal {
    private var terminal: GhosttyTerminal?

    /// Scrollback kept, in lines (about: libghostty prunes whole pages).
    static let scrollbackLines = 10_000

    init?(cols: Int, rows: Int) {
        var made: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &made, Self.clamp(cols), Self.clamp(rows)) == GHOSTTY_SUCCESS, let made else { return nil }
        terminal = made
        var lines = Self.scrollbackLines
        _ = ghostty_terminal_set(made, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
    }

    deinit {
        if let terminal { ghostty_terminal_free(terminal) }
    }

    func write(_ bytes: UnsafeRawBufferPointer) {
        guard let terminal, let base = bytes.bindMemory(to: UInt8.self).baseAddress, !bytes.isEmpty else { return }
        ghostty_terminal_vt_write(terminal, base, bytes.count)
    }

    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        guard let terminal else { return }
        _ = ghostty_terminal_resize(terminal, Self.clamp(cols), Self.clamp(rows), UInt32(max(cellWidth, 1)), UInt32(max(cellHeight, 1)))
    }

    /// VT bytes that rebuild this terminal in a fresh one of its size: at most `scrollback` rows
    /// of scrollback, the screen, the cursor, the modes.
    func snapshot(scrollback: Int) -> Data? {
        guard let terminal else { return nil }
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_terminal_vt_snapshot_alloc(terminal, UInt32(clamping: max(scrollback, 0)), nil, &pointer, &length) == GHOSTTY_SUCCESS else {
            return nil
        }
        guard let pointer else { return Data() }
        defer { ghostty_free(nil, pointer, length) }
        return Data(bytes: pointer, count: length)
    }

    private static func clamp(_ cells: Int) -> UInt16 { UInt16(clamping: min(max(cells, 1), 1000)) }
}
