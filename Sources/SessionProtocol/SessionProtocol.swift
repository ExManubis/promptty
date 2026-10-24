import Foundation

// What the app and prompttyd say to each other (PTY-77), over a Unix socket. prompttyd owns each
// pane's pty and the program on it, so shells keep running when the app quits; the app's surfaces
// are fed (libghostty's host backend) and, on the next launch, rebuilt from the daemon's own
// terminal of each pane (a VT snapshot) before they go live again.
//
// A frame is its length (4 bytes, big-endian: the kind and the payload), its kind (1 byte), then
// the payload: JSON for messages, a pane (16 bytes) and raw bytes for a pane's input and output,
// so a key or a chunk of output costs no encoding.

public enum SessionProtocol {
    /// Bumped when a message changes: an app and a daemon of different versions don't talk; the
    /// app runs its panes itself then.
    public static let version = 1
    /// The largest frame either side takes.
    public static let maxFrame = 64 << 20

    public enum Kind: UInt8, Sendable {
        /// App → daemon, first: `Hello`. Answered with `welcome`.
        case hello = 1
        /// `Welcome`.
        case welcome = 2
        /// App → daemon: `Open`, a pane's program, started unless the daemon runs it already.
        /// Answered with `opened`, then its output follows.
        case open = 3
        /// `Opened`.
        case opened = 4
        /// App → daemon: pane, then the bytes for its program (keys, paste, query replies).
        case input = 5
        /// Daemon → app: pane, then what its program wrote.
        case output = 6
        /// App → daemon: `Resize`.
        case resize = 7
        /// App → daemon: `PaneRef`, the pane closed: its program is hung up on (SIGHUP to its
        /// process group) and forgotten.
        case close = 8
        /// Daemon → app: `Status`, when the process in front or the pty's echo changes.
        case status = 9
        /// Daemon → app: `Exited`, the pane's program exited; the daemon forgets the pane.
        case exited = 10
        /// App → daemon: list the panes it runs. Answered with `sessions`.
        case list = 11
        /// `SessionList`.
        case sessions = 12
        /// App → daemon: `PaneRef`, no more output for this pane on this connection; it keeps
        /// running.
        case detach = 13
        /// Daemon → app: `SessionFailure`, a request that could not be done.
        case failed = 14
    }

    /// A frame's bytes.
    public static func frame(_ kind: Kind, _ payload: Data) -> Data {
        var frame = Data(capacity: 5 + payload.count)
        withUnsafeBytes(of: UInt32(1 + payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(kind.rawValue)
        frame.append(payload)
        return frame
    }

    /// A message as a frame.
    public static func frame<M: Encodable>(_ kind: Kind, _ message: M) -> Data {
        frame(kind, (try? JSONEncoder().encode(message)) ?? Data("{}".utf8))
    }

    /// A pane's input or output as a frame.
    public static func frame(_ kind: Kind, pane: UUID, bytes: Data) -> Data {
        var payload = Data(capacity: 16 + bytes.count)
        withUnsafeBytes(of: pane.uuid) { payload.append(contentsOf: $0) }
        payload.append(bytes)
        return frame(kind, payload)
    }

    /// The pane and bytes of an `input` or `output` payload.
    public static func paneBytes(_ payload: Data) -> (pane: UUID, bytes: Data)? {
        guard payload.count >= 16 else { return nil }
        let start = payload.startIndex
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuid) { $0.copyBytes(from: payload[start..<start + 16]) }
        return (UUID(uuid: uuid), Data(payload[(start + 16)...]))
    }

    public static func decode<M: Decodable>(_ type: M.Type, _ payload: Data) -> M? {
        try? JSONDecoder().decode(type, from: payload)
    }
}

/// Takes bytes as they arrive and gives back the whole frames among them.
public struct SessionFrameReader: Sendable {
    private var buffer = Data()

    public init() {}

    public enum Failure: Error, Equatable {
        /// A frame larger than `SessionProtocol.maxFrame`, or of no length: the peer is hung up on.
        case badFrame
    }

    /// The frames `bytes` completes, in order.
    public mutating func read(_ bytes: Data) throws -> [(kind: UInt8, payload: Data)] {
        buffer.append(bytes)
        var frames: [(kind: UInt8, payload: Data)] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 4 {
            let length = buffer[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= SessionProtocol.maxFrame else { throw Failure.badFrame }
            guard buffer.endIndex - offset >= 4 + length else { break }
            let kind = buffer[offset + 4]
            frames.append((kind, Data(buffer[(offset + 5)..<(offset + 4 + length)])))
            offset += 4 + length
        }
        if offset > buffer.startIndex { buffer = Data(buffer[offset...]) }
        return frames
    }
}

public struct Hello: Codable, Sendable {
    public var version: Int
    public var client: String

    public init(version: Int = SessionProtocol.version, client: String) {
        self.version = version
        self.client = client
    }
}

public struct Welcome: Codable, Sendable {
    public var version: Int
    /// The daemon's process, and the build it is (its executable's modification time), so an app
    /// can tell an older daemon from its own.
    public var pid: Int32
    public var build: String

    public init(version: Int = SessionProtocol.version, pid: Int32, build: String) {
        self.version = version
        self.pid = pid
        self.build = build
    }
}

/// A pane's program: what libghostty would have started (`ghostty_surface_exec_plan`), at the
/// surface's grid.
public struct Open: Codable, Sendable {
    public var pane: UUID
    /// argv, `args[0]` an absolute path (`/usr/bin/login` for a shell on macOS).
    public var args: [String]
    public var env: [String: String]
    public var cwd: String?
    public var cols: Int
    public var rows: Int
    public var widthPx: Int
    public var heightPx: Int
    /// Rows of scrollback in the snapshot of a pane the daemon runs already.
    public var scrollback: Int

    public init(pane: UUID, args: [String], env: [String: String], cwd: String?, cols: Int, rows: Int,
                widthPx: Int, heightPx: Int, scrollback: Int = 10_000) {
        self.pane = pane
        self.args = args
        self.env = env
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.scrollback = scrollback
    }
}

public struct Opened: Codable, Sendable {
    public var pane: UUID
    public var pid: Int32
    /// The daemon ran it already (the app quit and came back): `snapshot` rebuilds the surface,
    /// and the output after it follows.
    public var reattached: Bool
    /// VT bytes that rebuild the pane's terminal in a fresh one of `cols` × `rows`
    /// (`ghostty_terminal_vt_snapshot_alloc`); nil for a program just started.
    public var snapshot: Data?
    public var cols: Int
    public var rows: Int
    /// The process in front and the pty's mode, as `status` says them.
    public var status: Status

    public init(pane: UUID, pid: Int32, reattached: Bool, snapshot: Data?, cols: Int, rows: Int, status: Status) {
        self.pane = pane
        self.pid = pid
        self.reattached = reattached
        self.snapshot = snapshot
        self.cols = cols
        self.rows = rows
        self.status = status
    }
}

public struct Resize: Codable, Sendable {
    public var pane: UUID
    public var cols: Int
    public var rows: Int
    public var widthPx: Int
    public var heightPx: Int

    public init(pane: UUID, cols: Int, rows: Int, widthPx: Int, heightPx: Int) {
        self.pane = pane
        self.cols = cols
        self.rows = rows
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

public struct PaneRef: Codable, Sendable {
    public var pane: UUID

    public init(pane: UUID) { self.pane = pane }
}

/// What the app asks its own pty about, answered from the daemon's.
public struct Status: Codable, Equatable, Sendable {
    public var pane: UUID
    /// The pty's foreground process group (`tcgetpgrp`): the shell at a prompt, a program while
    /// it runs.
    public var foreground: Int32?
    /// The program reads a password: canonical input with echo off.
    public var password: Bool

    public init(pane: UUID, foreground: Int32?, password: Bool) {
        self.pane = pane
        self.foreground = foreground
        self.password = password
    }
}

public struct Exited: Codable, Sendable {
    public var pane: UUID
    public var code: Int32
    public var runtimeMs: UInt64

    public init(pane: UUID, code: Int32, runtimeMs: UInt64) {
        self.pane = pane
        self.code = code
        self.runtimeMs = runtimeMs
    }
}

public struct SessionList: Codable, Sendable {
    public struct Session: Codable, Sendable {
        public var pane: UUID
        public var pid: Int32
        public var cols: Int
        public var rows: Int

        public init(pane: UUID, pid: Int32, cols: Int, rows: Int) {
            self.pane = pane
            self.pid = pid
            self.cols = cols
            self.rows = rows
        }
    }

    public var sessions: [Session]

    public init(sessions: [Session]) { self.sessions = sessions }
}

public struct SessionFailure: Codable, Sendable {
    public var pane: UUID?
    public var message: String

    public init(pane: UUID?, message: String) {
        self.pane = pane
        self.message = message
    }
}
