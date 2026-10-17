import AppKit
import CommandEditing
import Observation
import SwiftUI
import WorkspaceModel

@MainActor
@Observable
final class FolderPickerModel {
    var browser: FolderBrowser

    init(directory: String) {
        browser = FolderBrowser(directory: directory)
    }

    /// Lists the browsed folder off the main thread: a folder on a stalled network share must not
    /// hang the app.
    func load() async {
        let directory = browser.directory
        let names = await Task.detached(priority: .userInitiated) { Self.folders(in: directory) }.value
        browser.loaded(names, for: directory)
    }

    /// The names of the folders in `path`, symlinks to folders included; nil when it cannot be read.
    nonisolated static func folders(in path: String) -> [String]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return nil }
        return names.filter { name in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: (path as NSString).appendingPathComponent(name), isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}

/// The input bar's folder picker, like Warp's: the current folder's folders, filtered by typing.
/// ↑↓ select, → steps into a folder, ← goes up, ⏎ changes to the selection (or to the folder
/// being browsed), ⎋ closes.
struct FolderPickerView: View {
    let model: FolderPickerModel
    let choose: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        let browser = model.browser
        PickerPanel(
            icon: "folder",
            title: Tab.abbreviate(browser.directory),
            placeholder: "Filter folders",
            query: Binding(get: { model.browser.query }, set: { model.browser.query = $0 }),
            note: Self.note(for: browser),
            rowCount: browser.rows.count,
            selectedID: browser.selection.flatMap { browser.rows.indices.contains($0) ? AnyHashable(browser.rows[$0]) : nil },
            listID: browser.directory,
            hints: [("⏎", "cd"), ("→", "open"), ("←", "up"), ("esc", "close")],
            onCommand: handle
        ) {
            ForEach(Array(browser.rows.enumerated()), id: \.element) { index, row in
                let name = Self.name(of: row)
                PickerRow(
                    icon: row == .parent ? "arrow.turn.left.up" : "folder",
                    title: name,
                    selected: browser.selection == index,
                    accessibilityLabel: row == .parent ? "Parent folder" : nil,
                    accessibilityHint: "Changes to this folder",
                    open: { choose(model.browser.target(row: index)) }
                ) { hovering in
                    Button { model.browser.stepIn(row: index) } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: PickerPanel<EmptyView>.rowHeight - 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(browser.selection == index || hovering ? 1 : 0)
                    .help(row == .parent ? "Go up" : "Show folders inside")
                    .accessibilityLabel(row == .parent ? "Go up" : "Show folders in \(name)")
                }
                .id(row)
            }
        }
        .task(id: browser.directory) { await model.load() }
    }

    private static func name(of row: FolderBrowser.Row) -> String {
        switch row {
        case .parent: ".."
        case .folder(let name): name
        }
    }

    /// Below the rows: why there are no folders to show.
    private static func note(for browser: FolderBrowser) -> String? {
        switch browser.listing {
        case .unreadable: return "Can’t read this folder"
        case .loading: return browser.rows.count > 1 ? nil : "Loading…"
        case .loaded:
            guard browser.rows.filter({ $0 != .parent }).isEmpty else { return nil }
            return browser.query.isEmpty ? "No folders" : "No matching folders"
        }
    }

    private func handle(_ command: PickerField.Command) -> Bool {
        switch command {
        case .up: model.browser.moveSelection(by: -1)
        case .down: model.browser.moveSelection(by: 1)
        case .right: return model.browser.stepIn()
        case .left:
            guard model.browser.query.isEmpty else { return false }
            model.browser.goUp()
        case .enter, .commandEnter:
            if let choice = model.browser.choice { choose(choice) }
        case .escape: cancel()
        }
        return true
    }
}
