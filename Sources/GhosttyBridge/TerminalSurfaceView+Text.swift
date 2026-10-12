import GhosttyKit

extension TerminalSurfaceView {
    /// Sends `text` to the terminal as if pasted (no key encoding).
    public func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in ghostty_surface_text(surface, ptr, UInt(strlen(ptr))) }
    }

    /// The text currently visible in the viewport, one line per row, or nil before the surface exists.
    public func visibleText() -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)), as: UTF8.self)
    }
}
