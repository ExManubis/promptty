import PaneActivity
import SwiftUI

/// The top of the sidebar while agents run: every agent in every window, what it is doing and
/// since when. A click brings its pane forward.
struct AgentsSection: View {
    let actions: ChromeActions

    var body: some View {
        let agents = actions.agents()
        if !agents.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(agents) { agent in
                    AgentRow(agent: agent) { actions.reveal(agent.pane) }
                }
                Divider()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Agents")
        }
    }
}

private struct AgentRow: View {
    let agent: AgentEntry
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
                    // Durations tick while the row is shown.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.state(of: agent.activity, now: context.date))
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
                RowBackground(selected: false, hovering: hovering)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show \(agent.program.name)")
        .accessibilityElement(children: .combine)
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
