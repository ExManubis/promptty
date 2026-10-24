import AppKit
import XCTest
import os
import GhosttyKit
@testable import GhosttyBridge

/// Engine patch 0006 on the Mac, where its renderer is the one the phone uses: a surface that
/// starts no program shows the bytes it is fed, and what the terminal sends back (a key, a
/// query's reply) reaches the write callback instead of a pty.
@MainActor
final class HostFedSurfaceTests: XCTestCase {
    /// Bytes from `io_write_cb`, appended on the IO thread.
    nonisolated static let written = OSAllocatedUnfairLock(initialState: Data())
    nonisolated static let grid = OSAllocatedUnfairLock(initialState: (columns: UInt16(0), rows: UInt16(0)))

    func testFedSurfaceShowsOutputAndSendsWhatIsTyped() throws {
        let runtime = try GhosttyRuntime(configURL: URL(fileURLWithPath: "/dev/null"))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.wantsLayer = true
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        cfg.scale_factor = 2
        cfg.io_write_cb = { _, bytes, len in
            guard let bytes else { return }
            let data = Data(bytes: bytes, count: len)
            HostFedSurfaceTests.written.withLock { $0.append(data) }
        }
        cfg.io_resize_cb = { _, columns, rows, _, _ in
            HostFedSurfaceTests.grid.withLock { $0 = (columns, rows) }
        }
        let surface = try XCTUnwrap(ghostty_surface_new(runtime.app, &cfg))
        defer { ghostty_surface_free(surface) }
        ghostty_surface_set_size(surface, 1280, 800)

        // Output goes on the screen; nothing was started to produce it.
        let output = Array("\u{1B}[1mhello\u{1B}[m from the Mac\r\n".utf8)
        ghostty_surface_feed(surface, output, output.count)
        XCTAssertTrue(screenText(surface).contains("hello from the Mac"))
        XCTAssertFalse(ghostty_surface_process_exited(surface))

        // A query is answered through the callback: the cursor position report (row 2, column 1).
        let query = Array("\u{1B}[6n".utf8)
        ghostty_surface_feed(surface, query, query.count)
        try waitForWritten("\u{1B}[2;1R")

        // A key goes the same way.
        var key = ghostty_input_key_s()
        key.keycode = 8  // kVK_ANSI_C
        key.mods = GHOSTTY_MODS_CTRL
        key.unshifted_codepoint = 0x63
        "c".withCString { text in
            key.text = text
            key.action = GHOSTTY_ACTION_PRESS
            _ = ghostty_surface_key(surface, key)
        }
        try waitForWritten("\u{03}")
        key = ghostty_input_key_s()
        key.keycode = 0x24  // kVK_Return, no text: the phone's key row sends it so
        key.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, key)
        try waitForWritten("\u{03}\r")

        // And the grid the surface now has.
        try wait { Self.grid.withLock { $0.columns > 0 && $0.rows > 0 } }
        let size = ghostty_surface_size(surface)
        XCTAssertEqual(Self.grid.withLock { $0.columns }, size.columns)
    }

    private func screenText(_ surface: ghostty_surface_t) -> String {
        var sel = ghostty_selection_s()
        sel.top_left = ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        sel.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    private func waitForWritten(_ expected: String) throws {
        try wait { String(decoding: Self.written.withLock { $0 }, as: UTF8.self).contains(expected) }
    }

    /// The callbacks run on the surface's IO thread.
    private func wait(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                let written = String(decoding: Self.written.withLock { $0 }, as: UTF8.self)
                throw NSError(domain: "HostFedSurfaceTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "timed out; written so far: \(written.debugDescription)"])
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
