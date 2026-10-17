import PaneActivity
import SwiftUI
import WorkspaceModel

/// One tab: a Dia-style single-line row in the sidebar (`.full`), a pill in the strip
/// (`.compact`), or a pinned tab's square tile (`.tile`), its programs' logos and nothing else.
struct TabRow: View {
    enum Style { case full, compact, tile }

    let tab: WorkspaceModel.Tab
    let index: Int
    let selected: Bool
    let style: Style
    let chrome: WindowChromeModel
    let actions: ChromeActions
    /// Tiles: where their preview goes (the sidebar's right edge, in window coordinates); nil
    /// shows none.
    var previewEdge: CGFloat?

    @State private var hovering = false
    /// The pointer has rested on the row: its preview shows.
    @State private var previewing = false
    @State private var previewTimer: Task<Void, Never>?
    /// The row's frame in the window, for placing its preview; known while the pointer is on the
    /// row, `.zero` otherwise.
    @State private var rowFrame: CGRect = .zero
    @State private var draft = ""
    @State private var lastTap: Date?
    @FocusState private var fieldFocused: Bool
    @Environment(\.sidebarOutOfSight) private var outOfSight

    private var renaming: Bool { chrome.renamingTab == tab.id }
    private var paneDropTarget: Bool { chrome.dropTargetTab == tab.id }
    private var previewShown: Bool { previewing || chrome.forcedPreview == tab.id }

    /// The tab's most urgent pane, for its activity dot and VoiceOver.
    private var display: PaneActivity.Display {
        stackCards.map(\.display).max() ?? .idle
    }

    private var stackPanes: [PaneID] {
        let ordered = tab.orderedPanes
        return (ordered.filter { $0.id == tab.focusedPaneID } + ordered.filter { $0.id != tab.focusedPaneID }).map(\.id)
    }

    private var stackCards: [ProgramStack.Card] {
        let ordered = tab.orderedPanes
        let panes = ordered.filter { $0.id == tab.focusedPaneID } + ordered.filter { $0.id != tab.focusedPaneID }
        return panes.map { pane in
            let activity = actions.activity(for: pane.id)
            return ProgramStack.Card(id: pane.id, program: activity.program, display: activity.display)
        }
    }

    var body: some View {
        content
            .background {
                RowBackground(selected: selected, hovering: hovering, dropTarget: paneDropTarget, resting: style == .tile)
            }
            .contentShape(Rectangle())
            .help(tooltip)
            .onHover { inside in
                hovering = inside
                updatePreview()
            }
            .background {
                // The frame matters only for a preview, which needs the pointer on the row:
                // tracked only then, not for every row on every frame of a scroll.
                if hovering || chrome.forcedPreview == tab.id {
                    Color.clear
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            let first = rowFrame == .zero
                            rowFrame = frame
                            // A preview asked for before the frame was known goes beside the row now.
                            if first, previewShown { actions.showPreview(of: tab.id, beside: previewAnchor, titled: style == .tile) }
                        }
                        .onDisappear { rowFrame = .zero }
                }
            }
            .onChange(of: previewShown) { _, shown in
                // Without the frame yet, the preview shows once it is known.
                if !shown {
                    actions.hidePreview(of: tab.id)
                } else if rowFrame != .zero {
                    actions.showPreview(of: tab.id, beside: previewAnchor, titled: style == .tile)
                }
            }
            .onChange(of: selected) { _, isSelected in
                if isSelected {
                    previewing = false
                    if chrome.forcedPreview == tab.id { chrome.forcedPreview = nil }
                }
            }
            .onDisappear { actions.hidePreview(of: tab.id) }
            // One tap recognizer that tells a double click from a single one itself. A separate
            // count-2 recognizer makes SwiftUI hold every single click until the double-click
            // interval has passed (0.5s by default) before the tab is selected.
            .onTapGesture {
                guard !renaming else { return }
                let now = Date()
                if let last = lastTap, now.timeIntervalSince(last) < NSEvent.doubleClickInterval {
                    lastTap = nil
                    beginRename()
                } else {
                    lastTap = now
                    actions.selectTab(tab.id)
                }
            }
            .onDrag {
                chrome.beginTabDrag(tab.id)
                return DragPayload.provider(DragPayload.tab, id: tab.id.rawValue)
            }
            .onDrop(of: [DragPayload.tab, DragPayload.pane], delegate: RowDropDelegate(tab: tab, index: index, chrome: chrome, actions: actions))
            .contextMenu { menu }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel([tab.listTitle, tab.pin != nil ? "pinned" : nil, agentsLabel ?? tab.listSubtitle, ActivityIndicator.label(for: display)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityAction(named: "Rename", beginRename)
            .accessibilityAction(named: tab.pin == nil ? "Pin" : "Unpin", togglePin)
            .accessibilityAction(named: "Close") { actions.requestCloseTab(tab.id) }
    }

    @ViewBuilder
    private var content: some View {
        if style == .tile {
            tileContent
        } else {
            rowContent
        }
    }

    /// The tile: its own icon or its programs centered. Renamed in a popover, having no title of
    /// its own.
    private var tileContent: some View {
        tileIcon
            // Larger in the sidebar's tiles (the ones that preview) than in the strip's pills.
            .scaleEffect(style == .tile && previewEdge != nil ? 1.25 : 1)
            .popover(isPresented: Binding(get: { chrome.iconPickerTab == tab.id && !outOfSight },
                                          set: { if !$0, chrome.iconPickerTab == tab.id { chrome.iconPickerTab = nil } }),
                     arrowEdge: .bottom) {
                PinIconPicker(current: tab.pin?.icon) { actions.setPinnedIcon(tab.id, $0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .popover(isPresented: Binding(get: { renaming && !outOfSight }, set: { if !$0, renaming { commitRename() } }), arrowEdge: .bottom) {
                TextField("Tab name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .padding(10)
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
            }
    }

    /// The icon the user chose, which stays whatever runs, or the logos.
    @ViewBuilder
    private var tileIcon: some View {
        if let icon = tab.pin?.icon {
            PinIconTile(icon: icon)
        } else {
            ProgramStack(cards: stackCards)
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            // The panes' programs as tiles, the focused one in front.
            ProgramStack(cards: stackCards)
                .frame(minWidth: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
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
                // In the sidebar, a tab running an agent says what its most urgent agent does.
                if style == .full, let agents {
                    AgentStatusLine(summary: agents)
                } else if style == .full {
                    // Otherwise, the ports its servers listen on.
                    TabPortsLine(panes: stackPanes, actions: actions)
                }
            }
            // The rest of the row's width, so the lines truncate only when they must.
            .frame(maxWidth: .infinity, alignment: .leading)
            // The progress and the activity, or under the pointer the close button.
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    TabProgressRing(panes: stackPanes, actions: actions)
                    // The strip's pills show only new output, no activity dot.
                    let newOutput = !selected && stackPanes.contains { actions.hasUnseenOutput($0) }
                    if style == .full {
                        ActivityIndicator(display: display, newOutput: newOutput)
                    } else if newOutput {
                        ActivityIndicator(display: .idle, newOutput: true)
                    }
                }
                .opacity(hovering && !renaming ? 0 : 1)
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
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: style == .full ? ChromeMetrics.tabRowHeight : 28)
    }

    /// The second line, for VoiceOver.
    private var agentsLabel: String? {
        guard style == .full, let agents else { return nil }
        let activity = agents.entry.status.activity
        return AgentListing.status(branch: agents.entry.repository.notableBranch, display: activity.display, tool: activity.tool,
                                   since: activity.agentSince, others: agents.others, now: Date())
    }

    /// The tab's agents, for its second line.
    private var agents: TabAgentSummary? { actions.agentList.summary(for: tab.id) }

    /// The title and folder; in the strip, which has no project headers, the project too.
    private var tooltip: String {
        let text = tab.listSubtitle.map { "\(tab.listTitle) — \($0)" } ?? tab.listTitle
        guard style != .full, let project = actions.projects.first(where: { $0.id == tab.projectID }) else { return text }
        return "\(project.name): \(text)"
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename…", action: beginRename)
        let projects = actions.projects
        Menu("Move to Project") {
            ForEach(projects, id: \.id) { project in
                Button(project.name) { actions.placeTab(tab.id, inProject: project.id, at: nil) }
                    .disabled(tab.projectID == project.id)
            }
            if !projects.isEmpty { Divider() }
            Button("New Project…") { actions.newProject(adding: tab.id) }
            if projects.contains(where: { $0.id == tab.projectID }) {
                Divider()
                Button("Remove from Project") { actions.placeTab(tab.id, inProject: nil, at: nil) }
            }
        }
        Button(tab.pin == nil ? "Pin Tab" : "Unpin Tab", action: togglePin)
        if let pin = tab.pin {
            Button("Reset Pinned Tab") { actions.resetPinnedTab(tab.id) }
                .help(pin.command.map { "Back to \(Tab.abbreviate(pin.directory)), running \($0)" } ?? "Back to \(Tab.abbreviate(pin.directory))")
            Button("Edit Pinned Command…") { actions.editPinnedCommand(tab.id) }
            Button("Change Icon…") { chrome.iconPickerTab = tab.id }
        }
        let ports = Array(Set(stackPanes.flatMap { actions.ports(for: $0) })).sorted()
        if !ports.isEmpty {
            Divider()
            ForEach(ports, id: \.self) { port in
                Button("Open localhost:\(port)") { actions.openPort(port) }
            }
            Divider()
        }
        Button("New Tab", action: actions.newTab)
        Divider()
        Button("Close Tab") { actions.requestCloseTab(tab.id) }
            .disabled(tab.pin != nil)
    }

    private func togglePin() {
        if tab.pin == nil { actions.pinTab(tab.id, at: nil) } else { actions.unpinTab(tab.id, at: nil) }
    }

    /// A row's preview goes beside it; a tile's beside the sidebar, past the other tiles.
    private var previewAnchor: CGRect {
        guard style == .tile, let previewEdge else { return rowFrame }
        return CGRect(x: rowFrame.minX, y: rowFrame.minY, width: max(previewEdge - rowFrame.minX, rowFrame.width), height: rowFrame.height)
    }

    /// Another tab of the sidebar, after the pointer has rested on it for half a second (not
    /// while something is dragged).
    private func updatePreview() {
        previewTimer?.cancel()
        let previews = style == .full || (style == .tile && previewEdge != nil)
        guard hovering, previews, !selected, !renaming, chrome.draggingPane == nil, chrome.draggingTab == nil else {
            previewing = false
            return
        }
        previewTimer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, hovering, !selected, !renaming, chrome.draggingPane == nil, chrome.draggingTab == nil,
                  NSEvent.pressedMouseButtons == 0 else { return }
            previewing = true
        }
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

/// Tab rows accept other tabs (reorder, into this row's project) and panes (move the pane into
/// this tab).
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
            // Onto a pinned tile it is pinned there; onto a row it is unpinned and moved there,
            // into the row's project (or out of any).
            let pinned = tab.pin != nil
            let project = tab.projectID
            chrome.draggingTab = nil
            return DragPayload.loadID(DragPayload.tab, from: info.itemProviders(for: [DragPayload.tab])) { [actions] id in
                if pinned {
                    actions.pinTab(TabID(rawValue: id), at: destination)
                } else {
                    actions.placeTab(TabID(rawValue: id), inProject: project, at: destination)
                }
            }
        }
    }
}

/// The row states: a Liquid Glass pill when selected, like the input box; a faint fill on hover.
struct RowBackground: View {
    let selected: Bool
    let hovering: Bool
    var dropTarget = false
    /// Tiles show their shape at rest too, like Dia's pinned tabs.
    var resting = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.rowCornerRadius, style: .continuous)
        if dropTarget {
            shape.fill(Color.accentColor.opacity(0.22))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5))
        } else if selected {
            Color.clear.glassEffect(.regular, in: shape)
        } else if hovering {
            shape.fill(Color.primary.opacity(colorScheme == .dark ? (resting ? 0.1 : 0.06) : (resting ? 0.09 : 0.05)))
        } else if resting {
            shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.045))
        }
    }
}

/// The dim "+ New Tab" row that ends the tab list: a tab in no project.
struct NewTabRow: View {
    let action: () -> Void
    var newProject: (() -> Void)?
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
        .contextMenu {
            Button("New Tab", action: action)
            if let newProject { Button("New Project…", action: newProject) }
        }
    }
}
