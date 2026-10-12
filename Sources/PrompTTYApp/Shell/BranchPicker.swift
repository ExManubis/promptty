import CommandEditing
import Observation
import SwiftUI

@MainActor
@Observable
final class BranchPickerModel {
    var list: BranchList
    let dirty: Bool

    init(current: String?, dirty: Bool) {
        list = BranchList(current: current)
        self.dirty = dirty
    }
}

/// The input bar's branch picker: local branches, newest commit first, filtered by typing, with
/// a row to create the typed name. ↑↓ select, ⏎ switches, ⎋ closes.
struct BranchPickerView: View {
    let model: BranchPickerModel
    let shell: PaneShell
    let choose: (BranchList.Row) -> Void
    let cancel: () -> Void

    var body: some View {
        let list = model.list
        PickerPanel(
            icon: "arrow.triangle.branch",
            title: list.current ?? "Branches",
            notice: model.dirty ? "Uncommitted changes" : nil,
            placeholder: "Switch to or create a branch",
            query: Binding(get: { model.list.query }, set: { model.list.query = $0 }),
            note: Self.note(for: list),
            rowCount: list.rows.count,
            selectedID: list.selection.flatMap { list.rows.indices.contains($0) ? AnyHashable(list.rows[$0]) : nil },
            hints: [("⏎", "switch"), ("↑↓", "select"), ("esc", "close")],
            onCommand: handle
        ) {
            ForEach(Array(list.rows.enumerated()), id: \.element) { index, row in
                PickerRow(
                    icon: Self.icon(for: row),
                    title: Self.title(for: row),
                    selected: list.selection == index,
                    dimmed: list.choice(row: index) == nil,
                    accessibilityHint: Self.hint(for: row, isCurrent: list.choice(row: index) == nil),
                    open: { if let choice = model.list.choice(row: index) { choose(choice) } }
                ) { _ in
                    if list.choice(row: index) == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22)
                            .accessibilityLabel("Current branch")
                    }
                }
                .id(row)
            }
        }
        .task {
            let names = await shell.listBranches()
            model.list.loaded(names)
        }
    }

    private static func icon(for row: BranchList.Row) -> String {
        if case .create = row { return "plus" }
        return "arrow.triangle.branch"
    }

    private static func title(for row: BranchList.Row) -> String {
        switch row {
        case .branch(let name): name
        case .create(let name): "Create branch “\(name)”"
        }
    }

    private static func hint(for row: BranchList.Row, isCurrent: Bool) -> String {
        if isCurrent { return "The branch checked out" }
        if case .create = row { return "Creates this branch and switches to it" }
        return "Switches to this branch"
    }

    /// In place of rows: why there are no branches to show.
    private static func note(for list: BranchList) -> String? {
        switch list.listing {
        case .loading: return "Loading…"
        case .unreadable: return "Can’t list the branches"
        case .loaded:
            guard list.rows.isEmpty else { return nil }
            return list.query.isEmpty ? "No branches" : "No matching branches"
        }
    }

    private func handle(_ command: PickerField.Command) -> Bool {
        switch command {
        case .up: model.list.moveSelection(by: -1)
        case .down: model.list.moveSelection(by: 1)
        case .left, .right: return false
        case .enter:
            if let choice = model.list.choice { choose(choice) }
        case .escape: cancel()
        }
        return true
    }
}
