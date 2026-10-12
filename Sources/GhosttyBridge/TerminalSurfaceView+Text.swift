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

    /// Presses Control and a letter: `d` (end of input) or `l` (clear screen).
    public func sendControl(_ letter: Character) {
        let codes: [Character: UInt32] = ["d": 2, "l": 37, "c": 8, "u": 32]
        guard let code = codes[letter], let scalar = letter.unicodeScalars.first else { return }
        let control = String(UnicodeScalar(UInt8(scalar.value & 0x1F)))
        sendKeyPress(keyCode: code, text: control, mods: GHOSTTY_MODS_CTRL, unshifted: scalar.value)
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
