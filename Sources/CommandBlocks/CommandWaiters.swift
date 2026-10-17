import Foundation

/// `promptty wait`: the replies waiting for commands to end, by command id, each with the pane the
/// command runs in. Every waiter is answered once: when its command ends, when its pane closes
/// (the command will never report its end), or not at all once it is cancelled (its timeout
/// answered). The answers are handed back to call, not called here.
public struct CommandWaiters<Pane: Hashable> {
    public enum Outcome {
        case finished(CommandRecord)
        /// The pane closed before the command ended.
        case paneClosed
    }

    public typealias Answer = (Outcome) -> Void

    private struct Waiter {
        let token: Int
        let pane: Pane
        let answer: Answer
    }

    private var waiting: [String: [Waiter]] = [:]
    private var nextToken = 0

    public init() {}

    public var isEmpty: Bool { waiting.isEmpty }
    public var count: Int { waiting.values.reduce(0) { $0 + $1.count } }

    /// Waits for command `id`, running in `pane`. Returns a token to cancel it with.
    @discardableResult
    public mutating func add(_ id: String, pane: Pane, answer: @escaping Answer) -> Int {
        nextToken += 1
        waiting[id, default: []].append(Waiter(token: nextToken, pane: pane, answer: answer))
        return nextToken
    }

    /// Forgets a waiter (answered some other way).
    public mutating func cancel(_ token: Int) {
        for (id, waiters) in waiting where waiters.contains(where: { $0.token == token }) {
            let rest = waiters.filter { $0.token != token }
            waiting[id] = rest.isEmpty ? nil : rest
            return
        }
    }

    /// `record` ended: the answers for its waiters, who are forgotten.
    public mutating func finished(_ record: CommandRecord) -> [() -> Void] {
        (waiting.removeValue(forKey: record.id) ?? []).map { w in { w.answer(.finished(record)) } }
    }

    /// `pane` closed: the answers for everyone waiting on a command there, who are forgotten.
    public mutating func paneClosed(_ pane: Pane) -> [() -> Void] {
        var answers: [() -> Void] = []
        for (id, waiters) in waiting {
            let (gone, rest) = (waiters.filter { $0.pane == pane }, waiters.filter { $0.pane != pane })
            guard !gone.isEmpty else { continue }
            answers += gone.map { w in { w.answer(.paneClosed) } }
            waiting[id] = rest.isEmpty ? nil : rest
        }
        return answers
    }
}
