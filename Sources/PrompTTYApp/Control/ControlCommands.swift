import CommandBlocks
import WorkspaceModel

/// The commands `promptty` handed out ids for, and the replies waiting for them to end.
@MainActor
final class ControlCommands {
    /// `promptty wait`: replies waiting for a command to end, or for its pane to close.
    private var waiters = CommandWaiters<PaneID>()
    /// Ids handed out for a command before its pane's shell runs it, and that pane.
    private(set) var pending: [String: (pane: PaneID, command: String)] = [:]

    /// An id was handed out for `command`, to run in `pane`.
    func handedOut(_ id: String, pane: PaneID, command: String) {
        pending[id] = (pane, command)
    }

    /// A handed-out id that started, or whose pane is gone.
    func forget(_ id: String) {
        pending[id] = nil
    }

    /// Waits for command `id`, running in `pane`. Returns a token to cancel it with.
    func wait(for id: String, in pane: PaneID, answer: @escaping CommandWaiters<PaneID>.Answer) -> Int {
        waiters.add(id, pane: pane, answer: answer)
    }

    /// Forgets a waiter (answered by its timeout).
    func cancel(_ token: Int) {
        waiters.cancel(token)
    }

    /// A command ended: its waiters get their answer.
    func finished(_ record: CommandRecord) {
        pending[record.id] = nil
        for answer in waiters.finished(record) { answer() }
    }

    /// Panes closed (or their shells stopped): a command there will never report its end, so whoever
    /// waits for one is answered now, and the ids handed out for commands they had not run yet are
    /// forgotten.
    func panesClosed(_ panes: some Sequence<PaneID>) {
        for pane in panes {
            pending = pending.filter { $0.value.pane != pane }
            for answer in waiters.paneClosed(pane) { answer() }
        }
    }
}
