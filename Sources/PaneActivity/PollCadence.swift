import Foundation

/// Decides which of several periodic jobs is due at a shared timer's tick: each job (a pane's
/// foreground check, its screen read) runs at its own interval, however often the timer fires.
public struct PollCadence<Key: Hashable> {
    private var last: [Key: Date] = [:]
    /// A timer with tolerance fires a little early or late; an interval counts as elapsed this
    /// close to its end, so a 0.5 s job does not slip to the tick after.
    private let slack: TimeInterval

    public init(slack: TimeInterval = 0.06) { self.slack = slack }

    /// True, and the job counted as run, when `interval` has passed since it last ran (or it never ran).
    public mutating func isDue(_ key: Key, every interval: TimeInterval, at now: Date) -> Bool {
        if let previous = last[key], now.timeIntervalSince(previous) < interval - slack { return false }
        last[key] = now
        return true
    }

    public mutating func forget(_ key: Key) { last[key] = nil }
}
