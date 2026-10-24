import Foundation

// Mirroring a pane: a client attaches to it and gets a snapshot of the terminal as VT bytes, then
// every byte the pane's programs write, numbered, so its own terminal shows what the Mac's does.
// It can type into the pane, and the device used last sizes it: attaching, typing or sending its
// grid fits the pane to the client, a click or a key in it on the Mac gives it the Mac's size back
// (tmux's `window-size latest`). Bytes travel base64 in JSON (`Data`'s Codable form), so every
// message is one JSON-RPC text frame like the rest of the protocol.
//
// A pane's output is one stream of bytes: `stream` names it and `seq` counts its bytes from 0. The
// snapshot holds everything before `seq`; each `output` event carries the bytes from its `seq` on,
// and the next one starts where it ended. A client that reconnects attaches with the stream and
// seq it got to (`resume`), and gets the bytes it missed instead of a snapshot while the Mac still
// has them.

extension RemoteProtocol.Method {
    /// Mirrors a pane (`AttachParams` → `Attached`); its `output` events follow.
    public static let attach = "attach"
    /// Stops mirroring a pane (`PaneParams` → `{}`); a pane it sized gets the Mac's size back.
    public static let detach = "detach"
    /// Types into an attached pane (`InputParams` → `{}`); the pane takes the client's grid.
    public static let input = "input"
    /// The client's grid, and that it is in use (`GridParams` → `MirrorState`): the pane takes it
    /// until another device is used, the client detaches or disconnects. Sent when the pane is
    /// tapped, the phone turns or the keyboard comes up.
    public static let resize = "resize"
}

extension RemoteProtocol.Event {
    /// An attached pane's output (`MirrorOutput`).
    public static let output = "output"
    /// An attached pane's size, whose grid it has or its password prompt changed (`MirrorState`).
    public static let paneState = "pane.state"
    /// The Mac stopped mirroring a pane to this client (`Detached`).
    public static let detached = "detached"
}

extension RemoteError {
    /// `input`, `control.take`, … for a pane this client has not attached to.
    public static let notAttached = -32005
    /// `input` while typing from other devices is off in the Mac's Settings.
    public static let typingOff = -32006
}

/// Where a client got to in a pane's output.
public struct MirrorPosition: Codable, Equatable, Sendable {
    public var stream: String
    public var seq: Int

    public init(stream: String, seq: Int) {
        self.stream = stream
        self.seq = seq
    }
}

public struct AttachParams: Codable, Equatable, Sendable {
    /// The pane, by id, id suffix or label, as `-p` names one.
    public var pane: String
    /// Where a client that was attached before got to: the output from there on instead of a
    /// snapshot, when the Mac still has it.
    public var resume: MirrorPosition?
    /// Rows of scrollback in the snapshot at most; 1000 when not given.
    public var scrollback: Int?
    /// The client's grid, when it knows it: the pane takes it.
    public var cols: Int?
    public var rows: Int?

    public init(pane: String, resume: MirrorPosition? = nil, scrollback: Int? = nil, cols: Int? = nil, rows: Int? = nil) {
        self.pane = pane
        self.resume = resume
        self.scrollback = scrollback
        self.cols = cols
        self.rows = rows
    }
}

/// `attach`'s result.
public struct Attached: Codable, Equatable, Sendable {
    /// The pane's id.
    public var pane: String
    /// The output stream and the seq the client is at now: the snapshot holds everything before
    /// it, or (resumed) the client had everything before it. The next `output` starts here.
    public var position: MirrorPosition
    /// VT bytes that rebuild the terminal in a fresh one of `state`'s size: the scrollback, the
    /// screen, the cursor, the modes (alternate screen, cursor visibility, bracketed paste, mouse
    /// reporting) and the colors programs changed. It starts with a full reset (`ESC c`). Nil
    /// when resumed.
    public var snapshot: Data?
    public var state: MirrorState

    public init(pane: String, position: MirrorPosition, snapshot: Data?, state: MirrorState) {
        self.pane = pane
        self.position = position
        self.snapshot = snapshot
        self.state = state
    }

    /// Resumed: the client's own terminal goes on from where it was.
    public var resumed: Bool { snapshot == nil }
}

/// What a mirrored pane is now, as one client sees it.
public struct MirrorState: Codable, Equatable, Sendable {
    public var pane: String
    /// The terminal's grid: the client's terminal has this size to show the output right.
    public var cols: Int
    public var rows: Int
    /// The output position the grid changed at, about: the bytes from here on are for this size.
    public var seq: Int
    /// The client whose grid the pane has, by the name it gave in `hello`; nil while the pane has
    /// the Mac's size.
    public var sizedBy: String?
    /// The pane has this client's grid.
    public var sizedByMe: Bool
    /// The program is reading a password (the terminal does not echo): a client hides what it
    /// echoes of the keys it sends.
    public var password: Bool
    /// The Mac lets this client type (Settings › Remote access).
    public var typing: Bool

    public init(pane: String, cols: Int, rows: Int, seq: Int, sizedBy: String? = nil, sizedByMe: Bool = false,
                password: Bool = false, typing: Bool = false) {
        self.pane = pane
        self.cols = cols
        self.rows = rows
        self.seq = seq
        self.sizedBy = sizedBy
        self.sizedByMe = sizedByMe
        self.password = password
        self.typing = typing
    }
}

/// `output`'s params.
public struct MirrorOutput: Codable, Equatable, Sendable {
    public var pane: String
    public var stream: String
    /// The position of the first byte: the end of the bytes before. A gap means bytes were lost;
    /// attach again.
    public var seq: Int
    public var data: Data

    public init(pane: String, stream: String, seq: Int, data: Data) {
        self.pane = pane
        self.stream = stream
        self.seq = seq
        self.data = data
    }
}

/// `detached`'s params.
public struct Detached: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// The pane closed.
        case closed
        /// The client fell too far behind the output; attach again for a fresh snapshot.
        case behind
        /// The Mac stopped remote access.
        case stopped
    }

    public var pane: String
    public var reason: Reason

    public init(pane: String, reason: Reason) {
        self.pane = pane
        self.reason = reason
    }
}

/// `detach`'s params.
public struct PaneParams: Codable, Equatable, Sendable {
    public var pane: String

    public init(pane: String) { self.pane = pane }
}

/// `resize`'s params: the client's grid.
public struct GridParams: Codable, Equatable, Sendable {
    public var pane: String
    public var cols: Int
    public var rows: Int

    public init(pane: String, cols: Int, rows: Int) {
        self.pane = pane
        self.cols = cols
        self.rows = rows
    }
}

/// `input`'s params: one of `text` (typed, each character a key press), `paste` (as if pasted:
/// bracketed when the program asked for that) or `key`.
public struct InputParams: Codable, Equatable, Sendable {
    public var pane: String
    public var text: String?
    public var paste: String?
    public var key: RemoteKey?

    public init(pane: String, text: String? = nil, paste: String? = nil, key: RemoteKey? = nil) {
        self.pane = pane
        self.text = text
        self.paste = paste
        self.key = key
    }
}

/// A key the phone's keyboard lacks or types differently: a named key, or a letter with Control.
public struct RemoteKey: Codable, Equatable, Sendable {
    /// `enter`, `tab`, `backspace`, `escape`, `delete`, `up`, `down`, `left`, `right`, `home`,
    /// `end`, `pageUp`, `pageDown`, `f1`…`f12`, or one letter, digit or punctuation character.
    public var key: String
    public var mods: [Mod]

    public enum Mod: String, Codable, Sendable, CaseIterable {
        case shift, ctrl, alt, `super`
    }

    public static let named: Set<String> = Set(["enter", "tab", "backspace", "escape", "delete", "up", "down", "left", "right",
                                            "home", "end", "pageUp", "pageDown"]).union((1...12).map { "f\($0)" })

    public init(_ key: String, mods: [Mod] = []) {
        self.key = key
        self.mods = mods
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        mods = try container.decodeIfPresent([Mod].self, forKey: .mods) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        if !mods.isEmpty { try container.encode(mods, forKey: .mods) }
    }

    private enum CodingKeys: String, CodingKey {
        case key, mods
    }

    /// A named key or a single character.
    public var isValid: Bool { Self.named.contains(key) || key.count == 1 }
}
