import CommandEditing
import Observation
import SwiftUI

@MainActor
@Observable
final class BranchPickerModel {
    var list: BranchList
    let git: GitStatus

    init(git: GitStatus) {
        // Detached, HEAD is no branch: every branch is a choice.
        list = BranchList(current: git.detached ? nil : git.branch)
        self.git = git
    }

    func loaded(_ listing: BranchListing?) {
        guard let listing else { return list.loaded(nil) }
        list.loaded(listing.local, remote: listing.remote, elsewhere: listing.checkedOutElsewhere(current: list.current))
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
            title: model.git.detached ? "Detached at \(model.git.branch)" : model.git.branch,
            notice: model.git.dirty ? "Uncommitted changes" : nil,
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
                    enabled: list.choice(row: index) != nil,
                    accessibilityHint: Self.hint(for: row, in: list),
                    open: { if let choice = model.list.choice(row: index) { choose(choice) } }
                ) { _ in
                    if case .branch(let name) = row, name == list.current {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22)
                            .accessibilityLabel("Current branch")
                    } else if case .branch(let name) = row, list.isCheckedOutElsewhere(name) {
                        Text("other worktree")
                            .font(.system(size: 10))
                            .padding(.trailing, 6)
                            .help("Checked out in another worktree; git switches to it only there")
                    }
                }
                .id(row)
            }
        }
        .task {
            model.loaded(await shell.listBranches())
        }
    }

    private static func icon(for row: BranchList.Row) -> String {
        switch row {
        case .branch: "arrow.triangle.branch"
        case .create: "plus"
        case .track: "arrow.down.circle"
        }
    }

    private static func title(for row: BranchList.Row) -> String {
        switch row {
        case .branch(let name): name
        case .create(let name): "Create branch “\(name)”"
        case .track(let name): "Track “\(name)”"
        }
    }

    private static func hint(for row: BranchList.Row, in list: BranchList) -> String {
        switch row {
        case .branch(let name) where name == list.current: "The branch checked out"
        case .branch(let name) where list.isCheckedOutElsewhere(name): "Checked out in another worktree"
        case .branch: "Switches to this branch"
        case .create: "Creates this branch and switches to it"
        case .track: "Creates a local branch that tracks this remote branch, and switches to it"
        }
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
        case .enter, .commandEnter:
            if let choice = model.list.choice { choose(choice) }
        case .escape: cancel()
        }
        return true
    }
}
