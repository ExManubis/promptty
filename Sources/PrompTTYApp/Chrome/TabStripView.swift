import SwiftUI
import WorkspaceModel

/// Horizontal tabs as flat pills in the titlebar band, right of the traffic lights.
struct TabStripView: View {
    let state: WindowState
    let chrome: WindowChromeModel
    let actions: ChromeActions

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabRow(tab: tab, index: index, selected: tab.id == state.selectedTabID, style: .compact, chrome: chrome, actions: actions)
                            .frame(minWidth: 110, idealWidth: 180, maxWidth: 220)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
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
