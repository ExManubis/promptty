/// What a program asked of the clipboard (OSC 52) that the user has to answer.
public enum ClipboardRequestKind: Equatable, Sendable {
    case read, write
}

/// One question to the user: which request it is (ids never repeat in a pane), and what it asks.
public struct ClipboardTicket: Equatable, Sendable {
    public let id: Int
    public let kind: ClipboardRequestKind
}

/// Binds an answer to the question it was given for.
enum ClipboardAnswer {
    /// An answer to anything but the request now pending is a denial: a program must not swap in
    /// another request under the user's click.
    static func resolve(_ decision: ClipboardDecision, answering id: Int, pending: Int?) -> ClipboardDecision {
        pending == id ? decision : .deny
    }
}

public enum ClipboardDecision: Equatable, Sendable {
    case allow, deny
    /// Allow, and answer the same kind of request from this pane without asking again.
    case alwaysAllow
}

/// What one pane's programs were allowed for good ("always allow for this pane").
struct ClipboardGrants: Equatable {
    private(set) var read = false
    private(set) var write = false

    func allows(_ kind: ClipboardRequestKind) -> Bool {
        kind == .read ? read : write
    }

    mutating func grant(_ kind: ClipboardRequestKind) {
        if kind == .read { read = true } else { write = true }
    }
}
