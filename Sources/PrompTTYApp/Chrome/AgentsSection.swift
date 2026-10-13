import PaneActivity
import SwiftUI
import WorkspaceModel

/// The top of the sidebar while agents run or projects exist: every agent in every window, what
/// it is doing and since when. A click brings its pane forward. Agents are grouped under the
/// projects of their tabs (every project shows, in order, even with no agents), then, for tabs in
/// no project, by repository. The agent in this window's focused pane is shown selected, like its
/// tab; folded away, its group's header is. An agent drags (as its tab) onto a project's header to
/// join it, and has a menu; project headers drag to reorder and have the project's menu.
struct AgentsSection: View {
    let actions: ChromeActions
    let chrome: WindowChromeModel
    /// The focused pane of this window's selected tab.
    let focusedPane: PaneID?
    /// The workspace's projects, in order.
    let projects: [Project]
    /// Repositories folded away, by root. Projects keep their own fold, saved with the session.
    @State private var collapsed: Set<String> = []

    var body: some View {
        let agents = actions.agents()
        if !agents.isEmpty || !projects.isEmpty {
            let byPane = Dictionary(uniqueKeysWithValues: agents.map { ($0.pane, $0) })
            let known = Set(projects.map { Self.key(for: $0.id) })
            let groups = AgentGroups.group(
                agents.map { agent in
                    let project = agent.projectID.map(Self.key(for:)).flatMap { known.contains($0) ? $0 : nil }
                    return AgentGroups.Item(id: agent.pane, key: project.map(AgentGroups.Key.project) ?? .repository(agent.repository.root),
                                            display: agent.activity.display)
                },
                projectOrder: projects.map { Self.key(for: $0.id) }
            )
            let byKey = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, $0) })
            let repositories = groups.filter { if case .repository = $0.key { true } else { false } }
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .padding(.bottom, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .contextMenu { Button("New Project…") { actions.newProject(adding: nil) } }
                    .accessibilityAddTraits(.isHeader)
                // One repository and no projects: a flat list. Otherwise a header for each group,
                // so a project's name shows even over a single agent.
                if repositories.count == 1, projects.isEmpty {
                    rows(repositories[0].items.compactMap { byPane[$0.id] })
                } else {
                    ForEach(projects, id: \.id) { project in
                        let group = byKey[.project(Self.key(for: project.id))]
                        let holdsFocus = group?.items.contains { $0.id == focusedPane } ?? false
                        ProjectHeader(project: project, count: group?.items.count ?? 0, noun: "agent", display: group?.display,
                                      selected: project.folded && holdsFocus, chrome: chrome, actions: actions)
                        if !project.folded {
                            if let group {
                                rows(group.items.compactMap { byPane[$0.id] })
                                    .padding(.leading, 8)
                            } else {
                                Text("No agents yet")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 26)
                                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                            }
                        }
                    }
                    ForEach(repositories, id: \.key) { group in
                        if case .repository(let root) = group.key {
                            let folded = collapsed.contains(root)
                            GroupHeader(title: (root as NSString).lastPathComponent, help: WorkspaceModel.Tab.abbreviate(root),
                                        count: group.items.count, noun: "agent", display: group.display, folded: folded,
                                        selected: folded && group.items.contains { $0.id == focusedPane }) {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    if folded { collapsed.remove(root) } else { collapsed.insert(root) }
                                }
                            }
                            if !folded {
                                rows(group.items.compactMap { byPane[$0.id] })
                                    .padding(.leading, 8)
                            }
                        }
                    }
                }
                Divider()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Agents")
        }
    }

    /// `AgentGroups` keys projects by string.
    private static func key(for project: ProjectID) -> String { project.rawValue.uuidString }

    private func rows(_ agents: [AgentEntry]) -> some View {
        ForEach(agents) { agent in
            AgentRow(agent: agent, selected: agent.pane == focusedPane, chrome: chrome, actions: actions)
        }
    }
}

private struct AgentRow: View {
    let agent: AgentEntry
    /// The agent in this window's focused pane.
    let selected: Bool
    let chrome: WindowChromeModel
    let actions: ChromeActions
    @State private var hovering = false

    private func open() { actions.reveal(agent.pane) }

    var body: some View {
        // A tap, not a Button: a Button would swallow the drag.
        HStack(spacing: 8) {
            ProgramStack(cards: [ProgramStack.Card(id: agent.pane, program: agent.program, display: agent.activity.display)])
                .frame(minWidth: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(agent.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Durations tick while the row is shown; the branch tells parallel agents apart.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text([agent.repository.notableBranch, Self.state(of: agent.activity, now: context.date)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(agent.activity.display == .attention ? Color.orange : Color.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 2)
            ActivityIndicator(display: agent.activity.display)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 38)
        .background {
            RowBackground(selected: selected, hovering: hovering)
        }
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .onHover { hovering = $0 }
        .help("Show \(agent.program.name)")
        // Dragged, an agent is its tab: onto a project's header it moves the tab there.
        .onDrag {
            chrome.beginTabDrag(agent.tab)
            return DragPayload.provider(DragPayload.tab, id: agent.tab.rawValue)
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { open() }
        .accessibilityHint("Shows this agent's pane")
    }

    @ViewBuilder
    private var menu: some View {
        Button("Show \(agent.program.name)") { open() }
        Button("Rename Tab…") { actions.requestRenameTab(agent.tab) }
        let projects = actions.projects
        Menu("Move to Project") {
            ForEach(projects, id: \.id) { project in
                Button(project.name) { actions.placeTab(agent.tab, inProject: project.id) }
                    .disabled(agent.projectID == project.id)
            }
            if !projects.isEmpty { Divider() }
            Button("New Project…") { actions.newProject(adding: agent.tab) }
            if projects.contains(where: { $0.id == agent.projectID }) {
                Divider()
                Button("Remove from Project") { actions.placeTab(agent.tab, inProject: nil) }
            }
        }
    }

    /// "Working · 1 min 20 s", "Waiting · 5 min", "Your turn · 2 min".
    static func state(of activity: PaneActivity, now: Date) -> String {
        let label: String
        switch activity.display {
        case .attention: label = "Your turn"
        case .working: label = "Working"
        default: label = "Waiting"
        }
        guard let since = activity.agentSince else { return label }
        return "\(label) · \(Self.format(now.timeIntervalSince(since)))"
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
