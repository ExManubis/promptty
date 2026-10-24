import Foundation
import GhosttyKit

extension TerminalSurfaceView {
    /// Sends `text` to the terminal as if pasted (no key encoding).
    public func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in ghostty_surface_text(surface, ptr, UInt(strlen(ptr))) }
    }

    /// Presses Return, as the keyboard would (so it is encoded right in every keyboard mode).
    public func sendReturn() {
        sendKeyPress(keyCode: 36, text: "\r", mods: GHOSTTY_MODS_NONE, unshifted: 13)
    }

    /// Presses Control and a letter: `d` (end of input) or `l` (clear screen). The key's text is
    /// the letter, as Ghostty's own app passes it: given the control character itself, the encoder
    /// takes it for an unusual key and sends `ESC [12;5u`, which a shell ignores.
    public func sendControl(_ letter: Character) {
        let codes: [Character: UInt32] = ["d": 2, "l": 37, "c": 8, "u": 32]
        guard let code = codes[letter], let scalar = letter.unicodeScalars.first else { return }
        sendKeyPress(keyCode: code, text: String(letter), mods: GHOSTTY_MODS_CTRL, unshifted: scalar.value)
    }

    /// Answers the program's prompt for a choice with `key`, as pressing it here would, and marks
    /// the answer as a key pressed here does (`lastAnswerKey`): an agent's wait for permission ends.
    public func answerPrompt(_ key: PromptKey) {
        switch key {
        case .return: sendReturn()
        case .escape: sendKeyPress(keyCode: UInt32(PromptAnswerKey.escape), text: "\u{1b}", mods: GHOSTTY_MODS_NONE, unshifted: 0)
        case .yes: sendKeyPress(keyCode: 16, text: "y", mods: GHOSTTY_MODS_NONE, unshifted: 121)
        case .no: sendKeyPress(keyCode: 45, text: "n", mods: GHOSTTY_MODS_NONE, unshifted: 110)
        case .digit(let digit):
            guard (0...9).contains(digit) else { return }
            sendKeyPress(keyCode: PromptKey.digitCodes[digit], text: String(digit), mods: GHOSTTY_MODS_NONE, unshifted: 48 + UInt32(digit))
        case .interrupt: sendControl("c")
        }
        lastKeyPress = Date()
        lastAnswerKey = lastKeyPress
    }

    private func sendKeyPress(keyCode: UInt32, text: String, mods: ghostty_input_mods_e, unshifted: UInt32) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.keycode = keyCode
        key.mods = mods
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.unshifted_codepoint = unshifted
        key.composing = false
        text.withCString { ptr in
            key.text = ptr
            key.action = GHOSTTY_ACTION_PRESS
            _ = ghostty_surface_key(surface, key)
        }
        key.text = nil
        key.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, key)
    }

    /// The selected text, or nil when nothing is selected.
    public func selectedText() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    /// The text currently visible in the viewport, one line per row, or nil before the surface exists.
    public func visibleText() -> String? {
        text(in: GHOSTTY_POINT_VIEWPORT)
    }

    /// The program's screen, whatever the user has scrolled back to.
    public func activeScreenText() -> String? {
        text(in: GHOSTTY_POINT_ACTIVE)
    }

    /// Everything the terminal holds, scrollback and screen, with its colors and styles as escape
    /// sequences (`vt`) or as plain text.
    public func allText(styled vt: Bool) -> String? {
        screenText(from: GHOSTTY_POINT_COORD_TOP_LEFT, row: 0, styled: vt)
    }

    /// The last `rows` rows the terminal holds (scrollback and screen), styled as `allText`: the
    /// rest of a long scrollback is never read or formatted.
    public func recentText(rows: Int, styled vt: Bool) -> String? {
        guard let total = blockSnapshot(.viewport)?.viewport.totalRows, total > rows else { return allText(styled: vt) }
        // The scrollback can change between the two reads: then everything, as before.
        return screenText(from: GHOSTTY_POINT_COORD_EXACT, row: total - rows, styled: vt) ?? allText(styled: vt)
    }

    /// Rows in the scrollback and on screen together, or nil before the surface exists.
    public var totalRows: Int? { blockSnapshot(.viewport)?.viewport.totalRows }

    private func screenText(from coord: ghostty_point_coord_e, row: Int, styled vt: Bool) -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: coord, x: 0, y: UInt32(clamping: row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text_format(surface, selection, vt ? GHOSTTY_TEXT_FORMAT_VT : GHOSTTY_TEXT_FORMAT_PLAIN, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    private func text(in tag: ghostty_point_tag_e) -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)), as: UTF8.self)
    }
}
