import SwiftUI
import WorkspaceModel

/// One tab in the sidebar (`.full`, two lines) or the strip (`.compact`, one line).
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
                .font(.system(size: style == .full ? 13 : 11, weight: .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Tab name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .focused($fieldFocused)
                        .onSubmit(commitRename)
                        .onExitCommand(perform: cancelRename)
                        .onChange(of: fieldFocused) { _, focused in if !focused, renaming { commitRename() } }
                } else {
                    Text(tab.listTitle)
                        .font(.system(size: style == .full ? 13 : 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if style == .full, let subtitle = tab.listSubtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(minHeight: style == .full ? 32 : nil)
            Spacer(minLength: 2)
            Button { actions.requestCloseTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering && !renaming ? 1 : 0)
            .help("Close Tab")
            .accessibilityLabel("Close \(tab.listTitle)")
        }
        .padding(.horizontal, style == .full ? 10 : 10)
        .padding(.vertical, style == .full ? 7 : 5)
        .background {
            let shape = RoundedRectangle(cornerRadius: style == .full ? 10 : 14, style: .continuous)
            if paneDropTarget {
                shape.fill(Color.accentColor.opacity(0.25)).overlay(shape.strokeBorder(Color.accentColor, lineWidth: 1.5))
            } else if selected {
                shape.fill(Color.accentColor.opacity(0.16))
            } else if hovering {
                shape.fill(Color.primary.opacity(0.05))
            }
        }
        .contentShape(Rectangle())
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
        draft = tab.customTitle ?? tab.displayTitle
        chrome.renamingTab = tab.id
        fieldFocused = true
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
