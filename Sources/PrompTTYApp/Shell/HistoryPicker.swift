import CommandEditing
import Observation
import SwiftUI

/// Ctrl-R's search over the shared history. The history is merged once, when the picker opens;
/// each key then filters the search's own copy.
@MainActor
@Observable
final class HistoryPickerModel {
    var query: String {
        didSet { if query != oldValue { refresh() } }
    }
    private(set) var results: [String] = []
    private(set) var selection: Int?
    /// Nil while the history is merged and indexed off the main thread.
    @ObservationIgnored private var search: HistorySearch?

    /// `history`: the shared history, merged here off the main thread. `folder`: the commands run
    /// here, best first. `seed`: what the bar holds, which starts the query.
    init(history: MergedHistory, folder: [String], seed: String) {
        query = seed
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                HistorySearch(newestFirst: Array(history), folder: folder)
            }.value
            self?.ready(built)
        }
    }

    private func ready(_ built: HistorySearch) {
        search = built
        refresh()
    }

    var isLoading: Bool { search == nil }
    var isEmpty: Bool { search?.isEmpty ?? true }

    var choice: String? { selection.flatMap { results.indices.contains($0) ? results[$0] : nil } }
    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max((selection ?? 0) + delta, 0), results.count - 1)
    }

    /// ⌃R: the next match, back to the first after the last.
    func nextMatch() {
        guard !results.isEmpty else { return }
        selection = ((selection ?? -1) + 1) % results.count
    }

    private func refresh() {
        guard search != nil else { return }
        results = search!.search(query)
        selection = results.isEmpty ? nil : 0
    }
}

/// The input bar's history search (⌃R): the history, newest first, with the commands run in this
/// folder on top, fuzzy-filtered by typing. ↑↓ and ⌃R select, ⏎ puts the command in the bar
/// without running it, ⎋ closes.
struct HistoryPickerView: View {
    let model: HistoryPickerModel
    let choose: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        PickerPanel(
            icon: "clock.arrow.circlepath",
            title: "History",
            placeholder: "Search history",
            query: Binding(get: { model.query }, set: { model.query = $0 }),
            note: model.results.isEmpty ? (model.isLoading ? "Loading…" : model.isEmpty ? "No history yet" : "No matching commands") : nil,
            rowCount: model.results.count,
            selectedID: model.choice.map { AnyHashable($0) },
            listID: 0,
            hints: [("⏎", "insert"), ("⌃R", "next"), ("esc", "close")],
            onCommand: handle,
            onControlR: { model.nextMatch() }
        ) {
            ForEach(Array(model.results.enumerated()), id: \.element) { index, command in
                PickerRow(
                    icon: "clock",
                    title: Self.oneLine(command),
                    selected: model.selection == index,
                    accessibilityHint: "Puts this command in the input bar",
                    open: { choose(command) }
                ) { _ in EmptyView() }
                .id(command)
            }
        }
    }

    /// A multi-line command on one row, its line breaks marked.
    private static func oneLine(_ command: String) -> String {
        command.contains("\n") ? command.replacingOccurrences(of: "\n", with: " ↵ ") : command
    }

    private func handle(_ command: PickerField.Command) -> Bool {
        switch command {
        case .up: model.moveSelection(by: -1)
        case .down: model.moveSelection(by: 1)
        case .left, .right: return false
        case .enter: if let choice = model.choice { choose(choice) }
        case .escape: cancel()
        }
        return true
    }
}
