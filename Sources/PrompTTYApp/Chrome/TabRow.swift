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
    /// Tiles: the sidebar's, drawn larger than the strip's.
    var largeTile = false

    @State private var hovering = false
    @State private var draft = ""
    @State private var lastTap: Date?
    @FocusState private var fieldFocused: Bool
    @Environment(\.sidebarOutOfSight) private var outOfSight

    private var renaming: Bool { chrome.renamingTab == tab.id }
    private var paneDropTarget: Bool { chrome.dropTargetTab == tab.id }

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
                // The strip draws its pills' segments itself (`TabStripView`); a drop still shows.
                if style != .compact || paneDropTarget {
                    RowBackground(selected: selected, hovering: hovering, dropTarget: paneDropTarget, resting: style == .tile)
                } else if hovering, !selected {
                    Capsule().fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
            .help(tooltip)
            .onHover { hovering = $0 }
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
        switch style {
        case .tile: tileContent
        case .full: sidebarRowContent
        case .compact: rowContent
        }
    }

    /// The pane the row stands for: its agent's, if it runs one, else the focused one.
    private var leadPane: Pane {
        agents.flatMap { tab.pane($0.entry.pane) } ?? tab.focusedPane
    }

    /// A sidebar row, one line as Rex's: the programs' tiles (a blue dot on them for what happened
    /// out of sight), the title and folder, "•••" while an agent works.
    private var sidebarRowContent: some View {
        let lead = leadPane
        let program = actions.activity(for: lead.id).program
        let marks = TabActivityMarks(tab: tab, selected: selected, actions: actions)
        // An agent's row reads its task alone, as Rex's do.
        let (title, folder) = agents != nil ? (tab.listTitle, nil)
            : PaneTitle.titleAndFolder(pane: lead, program: program, customTitle: tab.customTitle)
        return HStack(spacing: 9) {
            // The panes' programs as the strip's tiles, the focused one in front.
            SidebarTabIcon(cards: stackCards, badge: marks.badge)
                .animation(.easeOut(duration: 0.2), value: marks.badge)
            if renaming {
                TextField("Tab name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
                    .onChange(of: fieldFocused) { _, focused in if !focused, renaming { commitRename() } }
            } else {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                        .layoutPriority(1)
                    if let folder {
                        Text(folder)
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .truncationMode(.head)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                // The rest of the row's width, so the line truncates only when it must.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The progress and "•••", or under the pointer the close button.
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    TabProgressRing(panes: stackPanes, actions: actions)
                    if marks.working { WorkingDots() }
                }
                .opacity(hovering && !renaming ? 0 : 1)
                closeButton
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: ChromeMetrics.tabRowHeight)
    }

    private var closeButton: some View {
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

    /// The tile: its own icon or its programs centered. Renamed in a popover, having no title of
    /// its own.
    private var tileContent: some View {
        tileIcon
            // Larger in the sidebar's tiles than in the strip's pills.
            .scaleEffect(style == .tile && largeTile ? 1.25 : 1)
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
                } else if style == .compact {
                    // A strip pill, as Rex's tabs read: "Python ~/api", the folder dimmed.
                    let (title, folder) = PaneTitle.titleAndFolder(pane: tab.focusedPane, program: actions.activity(for: tab.focusedPaneID).program,
                                                                   customTitle: tab.customTitle)
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.8))
                            .layoutPriority(1)
                        if let folder {
                            Text(folder)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.tertiary)
                                .truncationMode(.head)
                        }
                    }
                    .lineLimit(1)
                }
            }
            // The rest of the row's width, so the lines truncate only when they must.
            .frame(maxWidth: .infinity, alignment: .leading)
            // The progress and the activity, or under the pointer the close button.
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    TabProgressRing(panes: stackPanes, actions: actions)
                    // The strip's pills show only new output, no activity dot.
                    if !selected, stackPanes.contains(where: { actions.hasUnseenOutput($0) }) {
                        ActivityIndicator(display: .idle, newOutput: true)
                    }
                }
                .opacity(hovering && !renaming ? 0 : 1)
                closeButton
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 28)
    }

    /// What the agent does, for VoiceOver (the Activity shows it).
    private var agentsLabel: String? {
        guard style == .full, let agents else { return nil }
        let activity = agents.entry.status.activity
        return AgentListing.activity(display: activity.display, tool: activity.tool)
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
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: SidebarTabIcon.size)
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
