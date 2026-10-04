import Foundation

/// Coalesces bursts of `schedule()` into one `action` after `delay` of quiet.
@MainActor
public final class DebouncedSaver {
    private let delay: Duration
    private let action: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    public init(delay: Duration, action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
    }

    public func schedule() {
        pending?.cancel()
        pending = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.pending = nil
            self.action()
        }
    }

    /// Runs the action now if one is pending.
    public func flush() {
        guard pending != nil else { return }
        pending?.cancel()
        pending = nil
        action()
    }
}
