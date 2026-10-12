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
        browser = FolderBrowser(directory: directory, list: Self.folders(in:))
    }

    /// The names of the folders in `path`, symlinks to folders included.
    nonisolated static func folders(in path: String) -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
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
    let choose: (String) -> Void
    let cancel: () -> Void
    @State private var model: FolderPickerModel

    private static let rowHeight: CGFloat = 24
    private static let maxRows = 10

    init(directory: String, choose: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.choose = choose
        self.cancel = cancel
        _model = State(initialValue: FolderPickerModel(directory: directory))
    }

    var body: some View {
        let browser = model.browser
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(Tab.abbreviate(browser.directory))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.top, 10)

            FolderFilterField(text: Binding(get: { model.browser.query }, set: { model.browser.query = $0 }), onCommand: handle)
                .frame(height: 22)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(browser.rows.enumerated()), id: \.offset) { index, row in
                            FolderRowView(
                                row: row,
                                selected: browser.selection == index,
                                height: Self.rowHeight,
                                open: { choose(model.browser.target(row: index)) },
                                stepIn: { model.browser.stepIn(row: index) }
                            )
                            .id(index)
                        }
                        if browser.rows.isEmpty {
                            Text(browser.query.isEmpty ? "No folders" : "No matching folders")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                        }
                    }
                    .padding(5)
                }
                .scrollIndicators(.never)
                .frame(height: CGFloat(min(max(browser.rows.count, 1), Self.maxRows)) * Self.rowHeight + 10)
                .onChange(of: browser.selection) { _, new in
                    if let new { proxy.scrollTo(new) }
                }
                .onChange(of: browser.directory) { _, _ in
                    proxy.scrollTo(model.browser.selection ?? 0)
                }
            }

            Divider()

            HStack(spacing: 12) {
                hint("⏎", "cd")
                hint("→", "open")
                hint("←", "up")
                Spacer(minLength: 0)
                hint("esc", "close")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(width: 320)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).fontWeight(.semibold)
            Text(label)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func handle(_ command: FolderFilterField.Command) -> Bool {
        switch command {
        case .up: model.browser.moveSelection(by: -1)
        case .down: model.browser.moveSelection(by: 1)
        case .right: return model.browser.stepIn()
        case .left:
            guard model.browser.query.isEmpty else { return false }
            model.browser.goUp()
        case .enter: choose(model.browser.target)
        case .escape: cancel()
        }
        return true
    }
}

private struct FolderRowView: View {
    let row: FolderBrowser.Row
    let selected: Bool
    let height: CGFloat
    let open: () -> Void
    let stepIn: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: row == .parent ? "arrow.turn.left.up" : "folder")
                        .imageScale(.small)
                        .frame(width: 16)
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                    Text(name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row == .parent ? "Parent folder" : name)
            .accessibilityHint("Changes to this folder")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: stepIn) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: height - 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
            .opacity(selected || hovering ? 1 : 0)
            .help(row == .parent ? "Go up" : "Show folders inside")
            .accessibilityLabel(row == .parent ? "Go up" : "Show folders in \(name)")
        }
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background {
            let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
            if selected {
                shape.fill(Color.accentColor.opacity(0.85))
            } else if hovering {
                shape.fill(Color.primary.opacity(0.06))
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private var name: String {
        switch row {
        case .parent: ".."
        case .folder(let name): name
        }
    }
}

/// The filter field. The arrows, ⏎ and ⎋ drive the list instead of the text, except ← and →
/// when they have nothing to do there.
struct FolderFilterField: NSViewRepresentable {
    enum Command { case up, down, left, right, enter, escape }

    @Binding var text: String
    /// Returns false to let the field handle the key as text editing.
    let onCommand: (Command) -> Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Filter folders"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.cell?.lineBreakMode = .byTruncatingTail
        // The popover takes the keys and the first click from the bar's window.
        DispatchQueue.main.async {
            field.window?.makeKey()
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FolderFilterField

        init(parent: FolderFilterField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onCommand(.up)
            case #selector(NSResponder.moveDown(_:)): parent.onCommand(.down)
            case #selector(NSResponder.moveLeft(_:)): parent.onCommand(.left)
            case #selector(NSResponder.moveRight(_:)): parent.onCommand(.right)
            case #selector(NSResponder.insertNewline(_:)): parent.onCommand(.enter)
            case #selector(NSResponder.cancelOperation(_:)): parent.onCommand(.escape)
            default: false
            }
        }
    }
}
