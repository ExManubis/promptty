import PrompTTYChrome
import SwiftUI
import WorkspaceModel

/// A pane's find bar, at its top right while open: the text to look for, "3 of 17", previous and
/// next, close. Return goes to the next match, ⇧Return the previous, Esc closes.
struct FindBar: View {
    let pane: PaneID
    let actions: ChromeActions

    var body: some View {
        if let find = actions.findState(for: pane) {
            FindField(pane: pane, find: find, actions: actions)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.opacity.combined(with: .offset(y: -4)))
        }
    }
}

private struct FindField: View {
    let pane: PaneID
    let find: PaneFind
    let actions: ChromeActions
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            TextField("Find", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)
                .focused($focused)
                .onSubmit { actions.findNavigate(in: pane, forward: true) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    actions.findNavigate(in: pane, forward: false)
                    return .handled
                }
                .onExitCommand { actions.closeFind(in: pane) }
                .onChange(of: text) { _, new in actions.setFindText(new, in: pane) }
            Text(FindCount.label(needle: find.needle, total: find.total, selected: find.selected))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(find.total == 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
            HeaderButton(symbol: "chevron.up", help: "Previous Match") { actions.findNavigate(in: pane, forward: false) }
                .disabled((find.total ?? 0) == 0)
            HeaderButton(symbol: "chevron.down", help: "Next Match") { actions.findNavigate(in: pane, forward: true) }
                .disabled((find.total ?? 0) == 0)
            HeaderButton(symbol: "xmark", help: "Close") { actions.closeFind(in: pane) }
                .padding(.trailing, 3)
        }
        .frame(height: 28)
        .background(FlatSurface(cornerRadius: 8))
        .onAppear {
            text = find.needle
            focused = true
        }
        .onChange(of: find.focusRequest) { focused = true }
        // Use Selection for Find puts the terminal's text in the field.
        .onChange(of: find.needle) { _, new in if new != text { text = new } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in terminal")
    }
}

/// What the bar says of the matches.
enum FindCount {
    static func label(needle: String, total: Int?, selected: Int?) -> String {
        guard !needle.isEmpty else { return "" }
        guard let total else { return "…" }
        if total == 0 { return "No matches" }
        guard let selected else { return total == 1 ? "1 match" : "\(total) matches" }
        return "\(min(selected + 1, total)) of \(total)"
    }
}
