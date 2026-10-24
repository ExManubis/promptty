import Foundation
import GhosttyKit

/// What libghostty would have started for a surface (`ghostty_surface_exec_plan`): the arguments
/// (shell integration injected, `login(1)` on macOS), the environment and the folder, for
/// prompttyd to run on a pty of its own.
public struct ExecPlan: Decodable, Sendable, Equatable {
    public var args: [String]
    public var env: [String: String]
    public var cwd: String?
}

/// A hosted surface's link to the program feeding it (libghostty's host backend; prompttyd runs
/// the program): its output goes in with `feed` from any thread, what the terminal writes (keys,
/// paste, query replies) and each new grid come out through the handlers, on the surface's IO
/// thread.
///
/// Two locks, never held together: `feed` can wait on the IO thread's mailbox, and the IO thread
/// takes the handlers' lock, so sharing one could deadlock.
public final class SurfaceHostLink: @unchecked Sendable {
    public typealias Write = @Sendable (Data) -> Void
    public typealias Resize = @Sendable (_ cols: Int, _ rows: Int, _ widthPx: Int, _ heightPx: Int) -> Void

    private let surfaceLock = NSLock()
    private var surface: UnsafeMutableRawPointer?
    private let handlerLock = NSLock()
    private var write: Write?
    private var resize: Resize?
    private var lastGrid: (cols: Int, rows: Int, widthPx: Int, heightPx: Int)?

    init() {}

    /// Where the terminal's writes and its grid go. A grid it had before is given at once.
    public func connect(write: @escaping Write, resize: @escaping Resize) {
        let grid = handlerLock.withLock { () -> (cols: Int, rows: Int, widthPx: Int, heightPx: Int)? in
            self.write = write
            self.resize = resize
            return lastGrid
        }
        if let grid { resize(grid.cols, grid.rows, grid.widthPx, grid.heightPx) }
    }

    /// The program's output, on screen. From any thread but the surface's own callbacks; nothing
    /// once the surface is gone.
    public func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        surfaceLock.withLock {
            guard let surface else { return }
            data.withUnsafeBytes { raw in
                ghostty_surface_feed(surface, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
            }
        }
    }

    func attach(_ surface: UnsafeMutableRawPointer) {
        surfaceLock.withLock { self.surface = surface }
    }

    /// Before the surface is freed: no feed is running, none follows.
    func invalidate() {
        surfaceLock.withLock { surface = nil }
        handlerLock.withLock {
            write = nil
            resize = nil
        }
    }

    // From the IO thread.

    fileprivate func written(_ data: Data) {
        handlerLock.withLock { write }?(data)
    }

    fileprivate func resized(cols: Int, rows: Int, widthPx: Int, heightPx: Int) {
        let handler = handlerLock.withLock { () -> Resize? in
            lastGrid = (cols, rows, widthPx, heightPx)
            return resize
        }
        handler?(cols, rows, widthPx, heightPx)
    }

    /// libghostty's callbacks; the userdata is the surface's view, which outlives its surface.
    static let writeCallback: ghostty_surface_io_write_cb = { userdata, bytes, length in
        guard let userdata, let bytes, length > 0 else { return }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        view.hostLink?.written(Data(bytes: bytes, count: length))
    }

    static let resizeCallback: ghostty_surface_io_resize_cb = { userdata, cols, rows, width, height in
        guard let userdata else { return }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        view.hostLink?.resized(cols: Int(cols), rows: Int(rows), widthPx: Int(width), heightPx: Int(height))
    }
}

extension TerminalSurfaceView {
    /// The plan libghostty made for a hosted surface, once it exists.
    func readExecPlan() -> ExecPlan? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_exec_plan(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return nil }
        let json = Data(bytes: pointer, count: Int(text.text_len))
        return try? JSONDecoder().decode(ExecPlan.self, from: json)
    }

    /// A hosted surface's program exited: libghostty handles it as its own child's exit (the
    /// pane shows it, or closes).
    public func hostExited(code: Int32, runtimeMs: UInt64) {
        guard let surface, hostLink != nil else { return }
        ghostty_surface_host_exited(surface, UInt32(bitPattern: code), runtimeMs)
    }
}
