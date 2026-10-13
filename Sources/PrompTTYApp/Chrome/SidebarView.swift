import SwiftUI
import WorkspaceModel

/// The sidebar, flush with the window background like Dia's: a band for the traffic lights,
/// the pinned tiles, the agents, each project's tabs under its header, the tabs in no project,
/// and a dim "+ New Tab" row.
struct SidebarView: View {
    let state: WindowState
    let workspace: Workspace
    let chrome: WindowChromeModel
    let actions: ChromeActions
    /// Shown as a peek over the panes while the sidebar is collapsed.
    var collapsed = false

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights' band, with Dia's sidebar button just right of them. Peeking, the
            // panel is inset from the window's corner, so the band is narrower by the inset and
            // shorter by twice it: its midline stays on the traffic lights'.
            HStack(spacing: 0) {
                Color.clear.frame(width: ChromeMetrics.trafficLightsWidth - (collapsed ? ChromeMetrics.inset : 0))
                ChromeIconButton(symbol: "sidebar.left", help: collapsed ? "Keep Sidebar Open" : "Hide Sidebar", action: actions.toggleSidebar)
                Spacer(minLength: 0)
            }
            .frame(height: ChromeMetrics.titlebarHeight - (collapsed ? 2 * ChromeMetrics.inset : 0))
            // Above the tab list, whose scroll view reaches up under the titlebar and would take
            // the button's clicks.
            .zIndex(1)

            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    PinnedTabsGrid(state: state, chrome: chrome, actions: actions)
                    AgentsSection(actions: actions, focusedPane: state.selectedTab?.focusedPaneID, projects: workspace.projects)
                    // The other tabs, after the pinned ones (their indexes are the window's): each
                    // project's, then those in none.
                    let others = Array(Array(state.tabs.enumerated()).dropFirst(state.pinnedCount))
                    ForEach(workspace.projects, id: \.id) { project in
                        ProjectSection(project: project, tabs: others.filter { state.project(of: $0.element) == project.id },
                                       state: state, chrome: chrome, actions: actions)
                    }
                    ForEach(others.filter { state.project(of: $0.element) == nil }, id: \.element.id) { index, tab in
                        TabRow(tab: tab, index: index, selected: tab.id == state.selectedTabID, style: .full, chrome: chrome, actions: actions)
                    }
                    NewTabRow(action: { actions.newTab(inProject: nil) }, newProject: { actions.newProject(adding: nil) })
                }
                .padding(.horizontal, ChromeMetrics.sidebarHorizontalPadding)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

/// A project in the tab list: its header, then its tabs unless folded. Dropping a tab on the
/// header puts it last in the project.
private struct ProjectSection: View {
    let project: Project
    /// The project's tabs in this window, with their indexes in the window.
    let tabs: [(offset: Int, element: WorkspaceModel.Tab)]
    let state: WindowState
    let chrome: WindowChromeModel
    let actions: ChromeActions
    @State private var dropTargeted = false

    var body: some View {
        let holdsSelection = tabs.contains { $0.element.id == state.selectedTabID }
        GroupHeader(title: project.name, help: WorkspaceModel.Tab.abbreviate(project.directory), symbol: GroupHeader.Symbol(project),
                    missing: !WorkspaceCoordinator.isFolder(project.directory),
                    count: tabs.count, noun: "tab", folded: project.folded,
                    selected: project.folded && holdsSelection, dropTarget: dropTargeted,
                    onAdd: { actions.newTab(inProject: project.id) }) {
            withAnimation(.easeOut(duration: 0.15)) { actions.setProjectFolded(project.id, !project.folded) }
        }
        .padding(.top, 4)
        .contextMenu { menu }
        .onDrop(of: [DragPayload.tab], isTargeted: $dropTargeted) { providers in
            chrome.draggingTab = nil
            return DragPayload.loadID(DragPayload.tab, from: providers) { [actions, project] id in
                actions.placeTab(TabID(rawValue: id), inProject: project.id, at: nil)
            }
        }
        .popover(isPresented: Binding(get: { chrome.iconPickerProject == project.id },
                                      set: { if !$0, chrome.iconPickerProject == project.id { chrome.iconPickerProject = nil } }),
                 arrowEdge: .trailing) {
            PinIconPicker(current: project.icon) { actions.setProjectIcon(project.id, $0) }
        }
        if !project.folded {
            ForEach(tabs, id: \.element.id) { index, tab in
                TabRow(tab: tab, index: index, selected: tab.id == state.selectedTabID, style: .full, chrome: chrome, actions: actions)
                    .padding(.leading, 8)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("New Tab in \(project.name)") { actions.newTab(inProject: project.id) }
        Divider()
        Button("Rename…") { actions.renameProject(project.id) }
        Button("Change Icon…") { chrome.iconPickerProject = project.id }
        Button("Change Folder…") { actions.changeProjectFolder(project.id) }
        Divider()
        let index = actions.projects.firstIndex { $0.id == project.id }
        Button("Move Up") { actions.moveProject(project.id, by: -1) }
            .disabled(index == 0)
        Button("Move Down") { actions.moveProject(project.id, by: 1) }
            .disabled(index == actions.projects.count - 1)
        Divider()
        Button("Remove Project…") { actions.requestRemoveProject(project.id) }
    }
}

/// A small borderless SF Symbol button used in the chrome.
struct ChromeIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
