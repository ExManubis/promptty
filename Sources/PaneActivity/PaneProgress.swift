import Foundation

/// A program's progress report for its pane (OSC 9;4, as ConEmu and Windows Terminal define it):
/// what the ring on the pane's rows shows. Ghostty's convention: one that is not renewed for
/// 15 s is dropped, as the program that set it may have died.
public struct PaneProgress: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case set, error, indeterminate, pause }

    /// How long a report stands without an update.
    public static let timeout: TimeInterval = 15

    public let kind: Kind
    /// How far along, 0...1; nil for an indeterminate report. An error or a pause without a
    /// value shows a full ring.
    public let fraction: Double?
    public let updated: Date

    /// A report as the terminal decodes it: `kind` nil removes the progress; `percent` is nil
    /// when the program gave none. Returns nil for a removal.
    public init?(kind: Kind?, percent: Int?, at now: Date) {
        guard let kind else { return nil }
        self.kind = kind
        self.updated = now
        let clamped = percent.map { Double(min(max($0, 0), 100)) / 100 }
        switch kind {
        case .indeterminate: fraction = nil
        case .set: fraction = clamped ?? 0
        case .error, .pause: fraction = clamped ?? 1
        }
    }

    /// Not renewed for longer than the timeout.
    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(updated) >= Self.timeout
    }
}
