import AppKit
import PaneActivity
import SwiftUI
import WorkspaceModel

// The sidebar's activity, as Rex shows it: three dots while an agent works, a blue dot on a tab's
// icon for what finished or wants the user while it was out of sight, and the Activity list (the
// eye at the top of the sidebar, ⌘.) of the tabs running agents.

/// What a tab shows of its activity in the sidebar.
struct TabActivityMarks: Equatable {
    /// An agent in the tab is working: "•••".
    var working = false
    /// Something finished, failed or wants the user while the tab was out of sight: a blue dot on
    /// its icon.
    var badge = false

    @MainActor
    init(tab: WorkspaceModel.Tab, selected: Bool, actions: ChromeActions) {
        for pane in tab.orderedPanes {
            let display = actions.display(for: pane.id)
            if display == .working { working = true }
            guard !selected else { continue }
            switch display {
            case .finished, .failed, .attention, .permission: badge = true
            default: if actions.hasUnseenOutput(pane.id) { badge = true }
            }
        }
    }

    init(working: Bool = false, badge: Bool = false) {
        self.working = working
        self.badge = badge
    }

    static func merged(_ marks: [TabActivityMarks]) -> TabActivityMarks {
        TabActivityMarks(working: marks.contains { $0.working }, badge: marks.contains { $0.badge })
    }
}

/// Rex's "•••" while an agent works: three dots brightening in turn. Looped in Core Animation
/// (see `LoopingLayerView`), so it costs the main thread nothing per frame; still under Reduce
/// Motion.
struct WorkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WorkingDotsLayer(color: colorScheme == .dark ? .white : .black, animated: !reduceMotion)
            .frame(width: 18, height: 6)
            .accessibilityElement()
            .accessibilityLabel("Working")
    }
}

private struct WorkingDotsLayer: NSViewRepresentable {
    let color: NSColor
    let animated: Bool

    func makeNSView(context: Context) -> DotsView { DotsView() }

    func updateNSView(_ view: DotsView, context: Context) {
        guard view.color != color || view.animated != animated else { return }
        view.color = color
        view.animated = animated
        view.restart()
    }

    final class DotsView: NSView {
        var color: NSColor = .white
        var animated = true
        private var dots: [CALayer] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            restart()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restart()
        }

        func restart() {
            guard let layer, bounds.width > 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if dots.isEmpty {
                dots = (0..<3).map { _ in CALayer() }
                dots.forEach(layer.addSublayer)
            }
            let size: CGFloat = 4
            let gap = (bounds.width - 3 * size) / 2
            let now = CACurrentMediaTime()
            for (index, dot) in dots.enumerated() {
                dot.frame = CGRect(x: CGFloat(index) * (size + gap), y: (bounds.height - size) / 2, width: size, height: size)
                dot.cornerRadius = size / 2
                dot.backgroundColor = color.cgColor
                dot.removeAllAnimations()
                dot.opacity = animated ? 0.25 : 0.6
                guard animated else { continue }
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = [0.25, 0.9, 0.25, 0.25]
                pulse.keyTimes = [0, 0.25, 0.55, 1]
                pulse.duration = 1.2
                pulse.repeatCount = .infinity
                pulse.beginTime = now + Double(index) * 0.2
                pulse.fillMode = .backwards
                dot.add(pulse, forKey: "pulse")
            }
            CATransaction.commit()
        }
    }
}

/// A tab's programs as the strip's pills show them (`ProgramStack`), with a blue dot on the front
/// tile's corner for what happened out of sight.
struct SidebarTabIcon: View {
    let cards: [ProgramStack.Card]
    var badge = false

    /// The width the rows' text lines up after, for the headers' symbols.
    static let size: CGFloat = ProgramStack.width

    var body: some View {
        ProgramStack(cards: cards)
            .overlay(alignment: .topLeading) {
                if badge {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                        .offset(x: ProgramStack.width - 4.5, y: -2.5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(minWidth: Self.size, alignment: .leading)
    }
}

/// "This Mac" above the projects, with its own symbol, as Rex heads each machine's tabs.
struct MachineHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: TabStripView.computerSymbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: SidebarTabIcon.size)
            Text("This Mac")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .frame(height: 26)
        .help(TabStripView.computerName)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The eye at the top of the sidebar: shows or hides the Activity (⌘.). A blue dot on it while the
/// list is hidden and an agent's tab has something new.
struct ActivityButton: View {
    let on: Bool
    let badge: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "eye.fill" : "eye")
                .font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(on ? 0.1 : hovering ? 0.07 : 0))
                )
                .overlay(alignment: .topTrailing) {
                    if badge && !on {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: -3, y: 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.primary : Color.secondary)
        .onHover { hovering = $0 }
        .help(on ? "Hide Activity" : "Show Activity")
        .accessibilityLabel(on ? "Hide Activity" : "Show Activity")
        .accessibilityValue(badge && !on ? "New activity" : "")
    }
}

/// The Activity: this window's tabs running agents, under their projects, each with what its
/// agent does and how long ago that changed.
struct ActivityList: View {
    let state: WindowState
    let workspace: Workspace
    let chrome: WindowChromeModel
    let actions: ChromeActions

    var body: some View {
        let agentTabs = state.tabs.filter { actions.agentList.summary(for: $0.id) != nil }
        if agentTabs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No agents running")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Tabs running Claude Code, Codex or another agent show up here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(workspace.projects, id: \.id) { project in
                let tabs = agentTabs.filter { state.project(of: $0) == project.id }
                if !tabs.isEmpty {
                    ProjectLabel(title: project.name)
                    ForEach(tabs, id: \.id) { tab in row(tab) }
                }
            }
            ForEach(agentTabs.filter { state.project(of: $0) == nil }, id: \.id) { tab in row(tab) }
        }
    }

    @ViewBuilder
    private func row(_ tab: WorkspaceModel.Tab) -> some View {
        if let summary = actions.agentList.summary(for: tab.id) {
            ActivityRow(tab: tab, summary: summary, selected: tab.id == state.selectedTabID, chrome: chrome, actions: actions)
        }
    }
}

/// A project's name above its tabs, as Rex labels them: plain and gray.
struct ProjectLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A tab in the Activity: its agent's title, what it does and how long ago that changed.
struct ActivityRow: View {
    let tab: WorkspaceModel.Tab
    let summary: TabAgentSummary
    let selected: Bool
    let chrome: WindowChromeModel
    let actions: ChromeActions
    @State private var hovering = false

    var body: some View {
        let marks = TabActivityMarks(tab: tab, selected: selected, actions: actions)
        let program = actions.activity(for: summary.entry.pane).program
        // Read here: only this row redraws as the agent's state changes.
        let activity = summary.entry.status.activity
        HStack(spacing: 9) {
            SidebarTabIcon(cards: [ProgramStack.Card(id: summary.entry.pane, program: program, display: activity.display)], badge: marks.badge)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tab.listTitle)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if marks.working { WorkingDots() }
                }
                HStack(spacing: 6) {
                    Text(AgentListing.activity(display: activity.display, tool: activity.tool)
                         + (AgentListing.others(summary.others).map { " · " + $0 } ?? ""))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let since = activity.agentSince {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(AgentListing.ago(context.date.timeIntervalSince(since)))
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background { RowBackground(selected: selected, hovering: hovering) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            actions.selectTab(tab.id)
            actions.reveal(summary.entry.pane)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
