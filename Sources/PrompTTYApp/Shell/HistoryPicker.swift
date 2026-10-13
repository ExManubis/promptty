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
    @ObservationIgnored private var search: HistorySearch

    /// `newestFirst`: the merged history. `folder`: the commands run here, best first. `seed`: what
    /// the bar holds, which starts the query.
    init(newestFirst: [String], folder: [String], seed: String) {
        search = HistorySearch(newestFirst: newestFirst, folder: folder)
        query = seed
        refresh()
    }

    var choice: String? { selection.flatMap { results.indices.contains($0) ? results[$0] : nil } }
    var isEmpty: Bool { search.isEmpty }

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
        results = search.search(query)
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
            note: model.results.isEmpty ? (model.isEmpty ? "No history yet" : "No matching commands") : nil,
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
                    title: command,
                    selected: model.selection == index,
                    accessibilityHint: "Puts this command in the input bar",
                    open: { choose(command) }
                ) { _ in EmptyView() }
                .id(command)
            }
        }
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
