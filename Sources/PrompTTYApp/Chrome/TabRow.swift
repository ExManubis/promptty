import SwiftUI
import WorkspaceModel

/// One tab: a Dia-style single-line row in the sidebar (`.full`) or a pill in the strip (`.compact`).
struct TabRow: View {
    enum Style { case full, compact }

    let tab: WorkspaceModel.Tab
    let index: Int
    let selected: Bool
    let style: Style
    let chrome: WindowChromeModel
    let actions: ChromeActions

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var renaming: Bool { chrome.renamingTab == tab.id }
    private var paneDropTarget: Bool { chrome.dropTargetTab == tab.id }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.hasSplits ? "rectangle.split.2x1" : "terminal")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            if renaming {
                TextField("Tab name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
                    .onChange(of: fieldFocused) { _, focused in if !focused, renaming { commitRename() } }
            } else {
                Text(tab.listTitle)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 2)
            Button { actions.requestCloseTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering && !renaming ? 1 : 0)
            .help("Close Tab")
            .accessibilityLabel("Close \(tab.listTitle)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: style == .full ? ChromeMetrics.rowHeight : 28)
        .background {
            RowBackground(selected: selected, hovering: hovering, dropTarget: paneDropTarget)
        }
        .contentShape(Rectangle())
        .help(tab.listSubtitle.map { "\(tab.listTitle) — \($0)" } ?? tab.listTitle)
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture().onEnded { if !renaming { actions.selectTab(tab.id) } })
        .onTapGesture(count: 2) { beginRename() }
        .onDrag { DragPayload.provider(DragPayload.tab, id: tab.id.rawValue) }
        .onDrop(of: [DragPayload.tab, DragPayload.pane], delegate: RowDropDelegate(tab: tab, index: index, chrome: chrome, actions: actions))
        .contextMenu {
            Button("Rename…", action: beginRename)
            Button("New Tab", action: actions.newTab)
            Divider()
            Button("Close Tab") { actions.requestCloseTab(tab.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel([tab.listTitle, tab.listSubtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction(named: "Rename", beginRename)
        .accessibilityAction(named: "Close") { actions.requestCloseTab(tab.id) }
    }

    private func beginRename() {
        draft = tab.customTitle ?? tab.listTitle
        chrome.renamingTab = tab.id
    }

    private func commitRename() {
        guard renaming else { return }
        chrome.renamingTab = nil
        actions.renameTab(tab.id, to: draft)
        actions.endRenaming()
    }

    private func cancelRename() {
        chrome.renamingTab = nil
        actions.endRenaming()
    }
}

/// Tab rows accept other tabs (reorder) and panes (move the pane into this tab).
private struct RowDropDelegate: DropDelegate {
    let tab: WorkspaceModel.Tab
    let index: Int
    let chrome: WindowChromeModel
    let actions: ChromeActions

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            if info.hasItemsConforming(to: [DragPayload.pane]) {
                // Moving a pane into its own tab means nothing.
                if let dragging = chrome.draggingPane, tab.pane(dragging) != nil {
                    chrome.dropTargetTab = nil
                    return DropProposal(operation: .forbidden)
                }
                chrome.dropTargetTab = tab.id
            }
            return DropProposal(operation: .move)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            if chrome.dropTargetTab == tab.id { chrome.dropTargetTab = nil }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            chrome.dropTargetTab = nil
            let target = tab.id
            let destination = index
            if DragPayload.loadID(DragPayload.pane, from: info.itemProviders(for: [DragPayload.pane]), completion: { [actions] id in
                chrome.draggingPane = nil
                actions.movePane(PaneID(rawValue: id), intoTab: target)
            }) {
                return true
            }
            return DragPayload.loadID(DragPayload.tab, from: info.itemProviders(for: [DragPayload.tab])) { [actions] id in
                actions.moveTab(TabID(rawValue: id), to: destination)
            }
        }
    }
}

/// Dia's row states: a soft fill when selected (a white pill with a faint shadow in light mode),
/// a fainter one on hover.
struct RowBackground: View {
    let selected: Bool
    let hovering: Bool
    var dropTarget = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.rowCornerRadius, style: .continuous)
        if dropTarget {
            shape.fill(Color.accentColor.opacity(0.22))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5))
        } else if selected {
            if colorScheme == .dark {
                shape.fill(Color.white.opacity(0.10))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5))
            } else {
                shape.fill(Color.white)
                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 0.5)
                    .overlay(shape.strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5))
            }
        } else if hovering {
            shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.05))
        }
    }
}

/// The dim "+ New Tab" row that ends the tab list.
struct NewTabRow: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 18)
                Text("New Tab")
                    .font(.system(size: 13))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .frame(height: ChromeMetrics.rowHeight)
            .background { RowBackground(selected: false, hovering: hovering) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New Tab")
    }
}
