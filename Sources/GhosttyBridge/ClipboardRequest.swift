/// What a program asked of the clipboard (OSC 52) that the user has to answer.
public enum ClipboardRequestKind: Equatable, Sendable {
    case read, write
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
