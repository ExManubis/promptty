import PaneActivity
import SwiftUI
import WorkspaceModel

/// The sidebar, flush with the window background like Dia's: a band for the traffic lights,
/// the pinned tiles, each project's tabs under its header, the tabs in no project, and a dim
/// "+ New Tab" row. A tab running an agent says on its row what the agent does.
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
                // Rex's eye: the tabs running agents, and what each does (⌘.).
                AgentNewsButton(state: state, chrome: chrome, actions: actions)
                    .padding(.trailing, ChromeMetrics.sidebarHorizontalPadding)
            }
            .frame(height: ChromeMetrics.titlebarHeight - (collapsed ? 2 * ChromeMetrics.inset : 0))
            // Above the tab list, whose scroll view reaches up under the titlebar and would take
            // the button's clicks.
            .zIndex(1)

            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    MachineHeader()
                    if chrome.showsActivity {
                        ActivityList(state: state, workspace: workspace, chrome: chrome, actions: actions)
                    } else {
                        tabList
                    }
                }
                .padding(.horizontal, ChromeMetrics.sidebarHorizontalPadding)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chrome.showsActivity ? "Activity" : "Tabs")
    }

    @ViewBuilder
    private var tabList: some View {
        PinnedTabsGrid(state: state, chrome: chrome, actions: actions)
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
}

/// The Activity button, with a dot on the eye when an agent's tab out of sight has something new.
/// A view of its own, so the agents' activity it reads redraws the button, not the sidebar.
private struct AgentNewsButton: View {
    let state: WindowState
    let chrome: WindowChromeModel
    let actions: ChromeActions

    var body: some View {
        ActivityButton(on: chrome.showsActivity, badge: agentNews, action: actions.toggleActivity)
    }

    private var agentNews: Bool {
        state.tabs.contains { tab in
            tab.id != state.selectedTabID && actions.agentList.summary(for: tab.id) != nil
                && TabActivityMarks(tab: tab, selected: false, actions: actions).badge
        }
    }
}

/// A project in the tab list: its header, then its tabs unless folded. Folded, the header shows
/// the activity of the tabs it hides.
private struct ProjectSection: View {
    let project: Project
    /// The project's tabs in this window, with their indexes in the window.
    let tabs: [(offset: Int, element: WorkspaceModel.Tab)]
    let state: WindowState
    let chrome: WindowChromeModel
    let actions: ChromeActions

    private var marks: TabActivityMarks {
        .merged(tabs.map { TabActivityMarks(tab: $0.element, selected: $0.element.id == state.selectedTabID, actions: actions) })
    }

    var body: some View {
        let holdsSelection = tabs.contains { $0.element.id == state.selectedTabID }
        ProjectHeader(project: project, count: tabs.count, noun: "tab", marks: project.folded ? marks : nil,
                      selected: project.folded && holdsSelection, chrome: chrome, actions: actions)
            .padding(.top, 4)
        if !project.folded {
            ForEach(tabs, id: \.element.id) { index, tab in
                TabRow(tab: tab, index: index, selected: tab.id == state.selectedTabID, style: .full, chrome: chrome, actions: actions)
            }
        }
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
