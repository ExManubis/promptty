import Foundation
import GhosttyKit

/// A terminal's size in cells.
public struct TerminalGrid: Equatable, Hashable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    /// Within what a terminal can sensibly be: a phone's grid comes from another device.
    public var clamped: TerminalGrid {
        TerminalGrid(cols: min(max(cols, 10), 500), rows: min(max(rows, 3), 300))
    }
}

/// The terminal's state as VT bytes, taken at an exact point of its output (`TerminalOutput`).
public struct TerminalSnapshot: Sendable, Equatable {
    /// Rebuild the terminal when fed to a fresh one of `grid`'s size (`ghostty_surface_read_vt_snapshot`).
    public var vt: Data
    public var grid: TerminalGrid
    /// The output it holds: everything before this position, nothing after.
    public var position: TerminalOutput.Position
}

/// Mirroring a pane to another device: what the terminal shows, typing into it as its keyboard
/// does, and a size of the device's own.
extension TerminalSurfaceView {
    /// The terminal's grid now, or nil before the surface exists.
    public var grid: TerminalGrid? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        return TerminalGrid(cols: Int(size.columns), rows: Int(size.rows))
    }

    /// The terminal's state, at most `scrollback` rows of scrollback with it, lined up with the
    /// output: subscribe (`output.subscribeNumbered`) first, and the chunks from the snapshot's
    /// position on are the ones after it.
    public func vtSnapshot(scrollback: Int) -> TerminalSnapshot? {
        guard let surface else { return nil }
        let box = SnapshotPoint(output: output)
        var text = ghostty_text_s()
        let read = withExtendedLifetime(box) {
            ghostty_surface_read_vt_snapshot(surface, UInt32(clamping: max(0, scrollback)), SnapshotPoint.callback,
                                             Unmanaged.passUnretained(box).toOpaque(), &text)
        }
        guard read else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let position = box.position else { return nil }
        let vt = text.text.map { Data(bytes: $0, count: Int(text.text_len)) } ?? Data()
        return TerminalSnapshot(vt: vt, grid: box.grid, position: position)
    }

    /// Whether the program reads a password: its terminal reads lines without echoing them (the
    /// test libghostty makes for secure input, which it only makes while the pane has focus).
    /// Reads the terminal's mode from its tty, so it holds whichever pane is in front.
    public var readsPassword: Bool {
        guard let surface else { return false }
        let name = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(name) }
        guard let ptr = name.ptr, name.len > 0 else { return false }
        let path = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(name.len)), as: UTF8.self)
        let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var mode = termios()
        guard tcgetattr(fd, &mode) == 0 else { return false }
        return mode.c_lflag & tcflag_t(ICANON) != 0 && mode.c_lflag & tcflag_t(ECHO) == 0
    }

    /// The pixel size that gives the terminal `grid`, with the padding it has now.
    func pixelSize(of grid: TerminalGrid) -> (UInt32, UInt32)? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        let cellWidth = Int(size.cell_width_px), cellHeight = Int(size.cell_height_px)
        guard cellWidth > 0, cellHeight > 0, size.columns > 0, size.rows > 0 else { return nil }
        // The padding and what is left over below a cell, kept: the grid comes out exact.
        let padWidth = max(0, Int(size.width_px) - Int(size.columns) * cellWidth)
        let padHeight = max(0, Int(size.height_px) - Int(size.rows) * cellHeight)
        let grid = grid.clamped
        return (UInt32(grid.cols * cellWidth + padWidth), UInt32(grid.rows * cellHeight + padHeight))
    }

    /// Types `text` as key presses, as the keyboard would: Return and Tab as those keys, a control
    /// character as Control and its letter, so each program gets them encoded its way.
    public func typeText(_ text: String) {
        for character in text {
            guard let press = RemoteKeyMap.press(for: character) else { continue }
            sendPress(press)
        }
    }

    /// Presses a named key (`RemoteKeyMap.named`) or a character, with modifiers.
    @discardableResult
    public func pressKey(_ key: String, shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) -> Bool {
        guard var press = RemoteKeyMap.press(named: key) ?? (key.count == 1 ? RemoteKeyMap.press(for: key.first!) : nil) else {
            return false
        }
        var raw = press.mods.rawValue
        if shift { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if control { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if option { raw |= GHOSTTY_MODS_ALT.rawValue }
        if command { raw |= GHOSTTY_MODS_SUPER.rawValue }
        press.mods = ghostty_input_mods_e(rawValue: raw)
        // Control and a letter: the letter is the text, as `sendControl` explains.
        if control, let scalar = key.unicodeScalars.first, key.count == 1, scalar.isASCII, scalar.properties.isAlphabetic {
            press.text = key.lowercased()
        }
        sendPress(press)
        return true
    }

    /// Pastes `text`, bracketed when the program asked for that.
    public func pasteText(_ text: String) { sendText(text) }

    private func sendPress(_ press: RemoteKeyMap.Press) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.keycode = press.keyCode
        key.mods = press.mods
        // As the keyboard's own presses: the modifiers that made the text (Shift for `:`).
        key.consumed_mods = ghostty_surface_key_translation_mods(surface, press.mods)
        key.unshifted_codepoint = press.unshifted
        key.composing = false
        key.action = GHOSTTY_ACTION_PRESS
        withOptionalCString(press.text) { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }
        key.text = nil
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
    }
}

/// Where `vtSnapshot` was taken in the output, told with the terminal locked.
private final class SnapshotPoint: @unchecked Sendable {
    let output: TerminalOutput
    var position: TerminalOutput.Position?
    var grid = TerminalGrid(cols: 0, rows: 0)

    init(output: TerminalOutput) { self.output = output }

    static let callback: ghostty_surface_snapshot_cb = { userdata, cols, rows in
        guard let userdata else { return }
        let point = Unmanaged<SnapshotPoint>.fromOpaque(userdata).takeUnretainedValue()
        point.position = point.output.position
        point.grid = TerminalGrid(cols: Int(cols), rows: Int(rows))
    }
}

/// Characters and named keys as the Mac's keyboard (US layout) presses them: a program that asks
/// for keys rather than text (the kitty keyboard protocol) is told the right one.
enum RemoteKeyMap {
    struct Press: Equatable {
        var keyCode: UInt32
        var mods: ghostty_input_mods_e
        var text: String?
        var unshifted: UInt32
    }

    /// A key code no key has: libghostty takes the press for its text alone.
    static let unidentified: UInt32 = 0xFFFF

    /// Named keys: their macOS key codes and what they type.
    static let named: [String: (code: UInt32, text: String?, unshifted: UInt32)] = [
        "enter": (36, "\r", 13), "tab": (48, "\t", 9), "backspace": (51, "\u{7f}", 127), "escape": (53, "\u{1b}", 27),
        "delete": (117, nil, 0), "up": (126, nil, 0), "down": (125, nil, 0), "left": (123, nil, 0), "right": (124, nil, 0),
        "home": (115, nil, 0), "end": (119, nil, 0), "pageUp": (116, nil, 0), "pageDown": (121, nil, 0),
        "f1": (122, nil, 0), "f2": (120, nil, 0), "f3": (99, nil, 0), "f4": (118, nil, 0), "f5": (96, nil, 0), "f6": (97, nil, 0),
        "f7": (98, nil, 0), "f8": (100, nil, 0), "f9": (101, nil, 0), "f10": (109, nil, 0), "f11": (103, nil, 0), "f12": (111, nil, 0),
    ]

    /// The US layout's unshifted characters and their key codes.
    static let codes: [Character: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]

    /// Shifted characters: the unshifted one on the same key.
    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=",
        "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func press(named name: String) -> Press? {
        guard let key = named[name] else { return nil }
        return Press(keyCode: key.code, mods: GHOSTTY_MODS_NONE, text: key.text, unshifted: key.unshifted)
    }

    static func press(for character: Character) -> Press? {
        switch character {
        case "\r", "\n", "\r\n": return press(named: "enter")
        case "\t": return press(named: "tab")
        case "\u{7f}", "\u{8}": return press(named: "backspace")
        case "\u{1b}": return press(named: "escape")
        default: break
        }
        guard let scalar = character.unicodeScalars.first else { return nil }
        // Control characters: Control and their letter (^C is Control-c).
        if character.unicodeScalars.count == 1, (1...26).contains(scalar.value) {
            let letter = Character(UnicodeScalar(scalar.value + 96)!)
            return Press(keyCode: codes[letter] ?? unidentified, mods: GHOSTTY_MODS_CTRL, text: String(letter), unshifted: scalar.value + 96)
        }
        if scalar.value < 32 { return nil }
        if let code = codes[character] {
            return Press(keyCode: code, mods: GHOSTTY_MODS_NONE, text: String(character), unshifted: scalar.value)
        }
        let lower = Character(character.lowercased())
        if character.isUppercase, character.isASCII, let code = codes[lower] {
            return Press(keyCode: code, mods: GHOSTTY_MODS_SHIFT, text: String(character), unshifted: lower.unicodeScalars.first!.value)
        }
        if let base = shifted[character], let code = codes[base] {
            return Press(keyCode: code, mods: GHOSTTY_MODS_SHIFT, text: String(character), unshifted: base.unicodeScalars.first!.value)
        }
        // Anything else (å, é, an emoji) is its text.
        return Press(keyCode: unidentified, mods: GHOSTTY_MODS_NONE, text: String(character), unshifted: scalar.value)
    }
}
