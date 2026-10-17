import SwiftUI
import SystemConfiguration
import WorkspaceModel

/// Horizontal tabs as pills in the titlebar band, as Rex lays them out: right of the traffic lights
/// the project with this Mac's name under it, then the tabs, then the palette and a new tab.
struct TabStripView: View {
    let state: WindowState
    let chrome: WindowChromeModel
    let actions: ChromeActions

    /// This Mac's name ("Mac Studio"), read once.
    static let computerName: String = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "This Mac"

    private var projectName: String {
        state.selectedTab.flatMap(state.project(of:)).flatMap { id in actions.projects.first { $0.id == id }?.name } ?? "PrompTTY"
    }

    /// A pill's part of its segment: the selected tab's own capsule, or a piece of the run of
    /// unselected tabs, rounded only at the run's ends.
    @ViewBuilder
    private func segment(at index: Int, selected: Bool) -> some View {
        if selected {
            let shape = RoundedRectangle(cornerRadius: ChromeMetrics.rowCornerRadius, style: .continuous)
            shape.fill(Color.primary.opacity(0.13))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        } else {
            let radius = ChromeMetrics.rowCornerRadius
            let startsRun = !continuesRun(before: index)
            let endsRun = !continuesRun(before: index + 1)
            UnevenRoundedRectangle(topLeadingRadius: startsRun ? radius : 0, bottomLeadingRadius: startsRun ? radius : 0,
                                   bottomTrailingRadius: endsRun ? radius : 0, topTrailingRadius: endsRun ? radius : 0,
                                   style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
    }

    /// Whether the tab at `index` and the one before it are in the same run of unselected tabs
    /// (unpinned, neither selected, same project).
    private func continuesRun(before index: Int) -> Bool {
        guard index > 0, index < state.tabs.count else { return false }
        let a = state.tabs[index - 1], b = state.tabs[index]
        return a.pin == nil && b.pin == nil && a.id != state.selectedTabID && b.id != state.selectedTabID
            && state.project(of: a) == state.project(of: b)
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "macwindow")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(projectName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(Self.computerName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .frame(maxWidth: 150, alignment: .leading)
            .padding(.trailing, 6)
            .accessibilityElement(children: .combine)
            ScrollView(.horizontal) {
                // Segmented, as Rex's: a run of unselected tabs shares one rounded segment, split by
                // hairlines; the selected tab is its own lighter capsule.
                HStack(spacing: 0) {
                    ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                        if tab.pin != nil {
                            // Pinned tabs: icon-only pills first, as in a browser's tab strip.
                            TabRow(tab: tab, index: index, selected: tab.id == state.selectedTabID, style: .tile, chrome: chrome, actions: actions)
                                .frame(width: 44, height: 28)
                                .padding(.trailing, 4)
                        } else {
                            // No project headers here: a thin line where one project's tabs end.
                            if index > state.pinnedCount, state.project(of: state.tabs[index - 1]) != state.project(of: tab) {
                                Divider()
                                    .frame(height: 16)
                                    .padding(.horizontal, 6)
                            }
                            // Between two unselected pills, a hairline, as Rex separates its tabs.
                            else if index > 0, state.tabs[index - 1].pin == nil, tab.id != state.selectedTabID,
                                    state.tabs[index - 1].id != state.selectedTabID {
                                // On the segment's fill, so the run stays one piece.
                                Rectangle()
                                    .fill(Color.primary.opacity(0.14))
                                    .frame(width: 1, height: 14)
                                    .frame(height: 28)
                                    .background(Color.primary.opacity(0.06))
                            }
                            let selected = tab.id == state.selectedTabID
                            TabRow(tab: tab, index: index, selected: selected, style: .compact, chrome: chrome, actions: actions)
                                .frame(minWidth: 96, maxWidth: 220)
                                .background { segment(at: index, selected: selected) }
                                .padding(.horizontal, selected ? 4 : 0)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            Spacer(minLength: 0)
            ChromeIconButton(symbol: "command", help: "Command Palette", action: actions.openPalette)
            ChromeIconButton(symbol: "plus", help: "New Tab", action: actions.newTab)
        }
        .padding(.leading, ChromeMetrics.trafficLightsWidth + 4)
        .padding(.trailing, ChromeMetrics.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

/// The titlebar band when the tab list is hidden: a way back to the tabs, the title, new tab.
struct CompactTitleBar: View {
    let state: WindowState
    let actions: ChromeActions

    var body: some View {
        HStack(spacing: 4) {
            ChromeIconButton(symbol: "sidebar.left", help: "Show Tabs", action: actions.toggleSidebar)
            Spacer()
            Text(state.selectedTab?.listTitle ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            ChromeIconButton(symbol: "plus", help: "New Tab", action: actions.newTab)
        }
        .padding(.leading, ChromeMetrics.trafficLightsWidth)
        .padding(.trailing, ChromeMetrics.inset)
    }
}
