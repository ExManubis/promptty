import PaneActivity
import SwiftUI

/// A tab row's second line while an agent runs in the tab: its most urgent agent's branch, state,
/// tool and since when, and how many others there are. Orange while the agent wants the user.
struct AgentStatusLine: View {
    let summary: TabAgentSummary

    var body: some View {
        // Read here, not in the row: only this line redraws as the agent's state changes.
        let activity = summary.entry.status.activity
        HStack(spacing: 0) {
            // Durations tick while the row is shown, each second only while they show seconds.
            TimelineView(SinceSchedule(since: activity.agentSince)) { context in
                Text(AgentListing.status(branch: summary.entry.repository.notableBranch, display: activity.display,
                                         tool: activity.tool, since: activity.agentSince, others: 0, now: context.date))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // A new schedule when the state's start moves: the one-second ticks start again.
            .id(activity.agentSince)
            // The count stays whole; the state before it truncates.
            if let others = AgentListing.others(summary.others) {
                Text(" · " + others)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(activity.display >= .attention ? Color.orange : Color.secondary)
    }
}

/// An agent's clock: when its "since" label next reads differently (every second for the first
/// minute, then every minute); never without one.
private struct SinceSchedule: TimelineSchedule {
    let since: Date?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        return AnyIterator {
            guard let date = next else { return nil }
            next = since.map { AgentListing.nextChange(since: $0, after: date) }
            return date
        }
    }
}
