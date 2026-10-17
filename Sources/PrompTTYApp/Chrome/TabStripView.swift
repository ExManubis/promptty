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

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(projectName)
                    .font(.system(size: 12, weight: .semibold))
                Text(Self.computerName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: 130, alignment: .leading)
            .padding(.trailing, 6)
            .accessibilityElement(children: .combine)
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                        if tab.pin != nil {
                            // Pinned tabs: icon-only pills first, as in a browser's tab strip.
                            TabRow(tab: tab, index: index, selected: tab.id == state.selectedTabID, style: .tile, chrome: chrome, actions: actions)
                                .frame(width: 44, height: 28)
                        } else {
                            // No project headers here: a thin line where one project's tabs end.
                            if index > state.pinnedCount, state.project(of: state.tabs[index - 1]) != state.project(of: tab) {
                                Divider()
                                    .frame(height: 16)
                                    .padding(.horizontal, 2)
                            }
                            // Between two unselected pills, a hairline, as Rex separates its tabs.
                            else if index > 0, state.tabs[index - 1].pin == nil, tab.id != state.selectedTabID,
                                    state.tabs[index - 1].id != state.selectedTabID {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.14))
                                    .frame(width: 1, height: 14)
                            }
                            TabRow(tab: tab, index: index, selected: tab.id == state.selectedTabID, style: .compact, chrome: chrome, actions: actions)
                                .frame(minWidth: 120, idealWidth: 200, maxWidth: 240)
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
