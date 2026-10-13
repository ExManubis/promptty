import PaneActivity
import SwiftUI
import WorkspaceModel

/// The top of the sidebar while agents run: every agent in every window, what it is doing and
/// since when. A click brings its pane forward. The agent in this window's focused pane is shown
/// selected, like its tab; folded away, its project's header is.
struct AgentsSection: View {
    let actions: ChromeActions
    /// The focused pane of this window's selected tab.
    let focusedPane: PaneID?
    /// Projects folded away, by root.
    @State private var collapsed: Set<String> = []

    var body: some View {
        let agents = actions.agents()
        if !agents.isEmpty {
            let byPane = Dictionary(uniqueKeysWithValues: agents.map { ($0.pane, $0) })
            let groups = AgentGroups.group(agents.map { AgentGroups.Item(id: $0.pane, root: $0.project.root, display: $0.activity.display) })
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                // One project: a flat list. Two or more: a header for each.
                if groups.count == 1 {
                    rows(groups[0].items.compactMap { byPane[$0.id] })
                } else {
                    ForEach(groups, id: \.root) { group in
                        let folded = collapsed.contains(group.root)
                        let holdsFocus = group.items.contains { $0.id == focusedPane }
                        ProjectHeader(root: group.root, count: group.items.count, display: group.display, folded: folded, selected: folded && holdsFocus) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if folded { collapsed.remove(group.root) } else { collapsed.insert(group.root) }
                            }
                        }
                        if !folded {
                            rows(group.items.compactMap { byPane[$0.id] })
                                .padding(.leading, 8)
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

    private func rows(_ agents: [AgentEntry]) -> some View {
        ForEach(agents) { agent in
            AgentRow(agent: agent, selected: agent.pane == focusedPane) { actions.reveal(agent.pane) }
        }
    }
}

/// A project's name above its agents: its most urgent agent's dot, a click folds it.
private struct ProjectHeader: View {
    let root: String
    let count: Int
    let display: PaneActivity.Display
    let folded: Bool
    /// Folded over the focused agent.
    let selected: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .frame(width: 10)
                Text((root as NSString).lastPathComponent)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if folded {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 2)
                // Folded, the header stands for its agents.
                if folded { ActivityIndicator(display: display) }
            }
            .foregroundStyle(Color.primary.opacity(0.8))
            .padding(.leading, 6)
            .padding(.trailing, 6)
            .frame(height: 24)
            .background { RowBackground(selected: selected, hovering: hovering) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Tab.abbreviate(root))
        .accessibilityLabel("\((root as NSString).lastPathComponent), \(count) \(count == 1 ? "agent" : "agents")")
        .accessibilityValue(folded ? (selected ? "Collapsed, holds the focused agent" : "Collapsed") : "Expanded")
        .accessibilityHint(folded ? "Shows its agents" : "Hides its agents")
    }
}

private struct AgentRow: View {
    let agent: AgentEntry
    /// The agent in this window's focused pane.
    let selected: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
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
                        Text([agent.project.notableBranch, Self.state(of: agent.activity, now: context.date)].compactMap { $0 }.joined(separator: " · "))
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
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show \(agent.program.name)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows this agent's pane")
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
