import Foundation

/// Spaces out the sizes a continuously resized terminal (a split divider being dragged) is given:
/// each one makes the shell reflow and redraw its screen, far more work than moving a card.
public struct ResizeThrottle: Sendable {
    /// The shortest time between two sizes sent.
    public static let interval: TimeInterval = 0.05

    private var lastSent: TimeInterval?

    public init() {}

    /// How long to wait at `now` before the next size may be sent; 0 when it may go now.
    public func wait(at now: TimeInterval) -> TimeInterval {
        guard let lastSent else { return 0 }
        return max(0, lastSent + Self.interval - now)
    }

    public mutating func noteSent(at now: TimeInterval) {
        lastSent = now
    }
}
