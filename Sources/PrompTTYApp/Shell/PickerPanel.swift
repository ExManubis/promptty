import AppKit
import SwiftUI

/// The input bar's pickers (folders, branches): a popover with a title, a filter field that keeps
/// the keys, a list, and key hints below it.
struct PickerPanel<Rows: View>: View {
    let icon: String
    let title: String
    /// A line under the title (the branch picker's uncommitted changes).
    var notice: String?
    let placeholder: String
    @Binding var query: String
    /// In place of rows: why there are none.
    let note: String?
    let rowCount: Int
    /// Scrolled into view when it changes: the selected row's id.
    let selectedID: AnyHashable?
    /// A new list (another folder) starts scrolled to the top.
    var listID: AnyHashable = 0
    let hints: [(key: String, label: String)]
    let onCommand: (PickerField.Command) -> Bool
    /// ⌃R in the filter field, for the pickers that take it (history search).
    var onControlR: (() -> Void)?
    var width: CGFloat = 320
    @ViewBuilder let rows: () -> Rows

    static var rowHeight: CGFloat { 28 }
    private static var maxRows: Int { 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .foregroundStyle(.secondary)
                if let notice {
                    Label(notice, systemImage: "circle.fill")
                        .labelStyle(NoticeLabelStyle())
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.top, 10)

            PickerField(text: $query, placeholder: placeholder, onCommand: onCommand, onControlR: onControlR, font: .systemFont(ofSize: 14))
                .frame(height: 22)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        rows()
                        if let note {
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                        }
                    }
                    .padding(5)
                }
                .scrollIndicators(.never)
                .id(listID)
                .frame(height: CGFloat(min(rowCount + (note == nil ? 0 : 1), Self.maxRows)) * Self.rowHeight + 10)
                .onChange(of: selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }

            Divider()

            HStack(spacing: 10) {
                ForEach(Array(hints.enumerated()), id: \.offset) { index, hint in
                    if index == hints.count - 1 { Spacer(minLength: 0) }
                    // Keycaps, as the command palette shows its keys.
                    HStack(spacing: 4) {
                        Text(hint.key)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 4)
                            .frame(minHeight: 16)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text(hint.label)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: width)
    }
}

private struct NoticeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 5))
            configuration.title
        }
    }
}

/// One row of a picker: clicking it chooses it; `accessory` sits at its trailing end.
struct PickerRow<Accessory: View>: View {
    let icon: String
    let title: String
    let selected: Bool
    /// Not a choice (the branch checked out): dimmed, and not a button.
    var enabled = true
    /// When the title does not read well (`..`).
    var accessibilityLabel: String?
    let accessibilityHint: String
    let open: () -> Void
    @ViewBuilder let accessory: (_ hovering: Bool) -> Accessory
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .imageScale(.small)
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(enabled || selected ? 1 : 0.6)
                    Spacer(minLength: 4)
                }
                .padding(.leading, 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(accessibilityLabel ?? title)
            .accessibilityHint(accessibilityHint)
            .accessibilityAddTraits(selected ? .isSelected : [])
            accessory(hovering)
                .foregroundStyle(.secondary)
        }
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, minHeight: PickerPanel<EmptyView>.rowHeight, maxHeight: PickerPanel<EmptyView>.rowHeight)
        .foregroundStyle(Color.primary)
        // A quiet highlight, as the command palette's.
        .background {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            if selected {
                shape.fill(Color.primary.opacity(0.12))
            } else if hovering {
                shape.fill(Color.primary.opacity(0.05))
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }
}

/// A picker's filter field. The arrows, ⏎ and ⎋ drive the list instead of the text, except ←
/// and → when the picker has nothing to do with them.
struct PickerField: NSViewRepresentable {
    /// `commandEnter`: ⌘Return, which pickers without a second choice treat as Return.
    enum Command { case up, down, left, right, enter, commandEnter, escape }

    @Binding var text: String
    let placeholder: String
    /// Returns false to let the field handle the key as text editing.
    let onCommand: (Command) -> Bool
    var onControlR: (() -> Void)?
    var font: NSFont = .systemFont(ofSize: 13)

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.delegate = context.coordinator
        field.cell?.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        (field as? FocusingTextField)?.onControlR = onControlR
        (field as? FocusingTextField)?.onCommandReturn = { _ = context.coordinator.parent.onCommand(.commandEnter) }
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PickerField

        init(parent: PickerField) { self.parent = parent }

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

/// Takes the keys once it is in the popover's window, and the window with it: the popover then
/// has the keys and the first click, not the bar's window behind it. On the next turn of the run
/// loop: a field made first responder before its first layout draws its placeholder as text.
private final class FocusingTextField: NSTextField {
    var onControlR: (() -> Void)?
    var onCommandReturn: (() -> Void)?

    /// ⌃R has no text-editing meaning, so it never reaches `doCommandBy`: seen here, before the
    /// field editor gets the key.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if let onControlR, mods == .control, event.charactersIgnoringModifiers?.lowercased() == "r" {
            onControlR()
            return true
        }
        // ⌘Return is a key equivalent, never a newline for the field.
        if let onCommandReturn, mods == .command, event.keyCode == 36 || event.keyCode == 76 {
            onCommandReturn()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                window.makeKey()
                window.makeFirstResponder(self)
            }
        }
    }
}
