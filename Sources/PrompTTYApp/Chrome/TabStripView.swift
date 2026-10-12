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

/// The toolbar row at the top of the content panel: sidebar toggle, then the focused pane's
/// title and folder. Its center lines up with the traffic lights.
struct PanelToolbar: View {
    let state: WindowState
    let sidebarHidden: Bool
    let actions: ChromeActions

    var body: some View {
        HStack(spacing: 8) {
            ChromeIconButton(symbol: "sidebar.left", help: sidebarHidden ? "Show Tabs" : "Hide Tabs", action: actions.toggleSidebar)
            if let tab = state.selectedTab {
                HStack(spacing: 6) {
                    Text(tab.listTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    if let folder = tab.listSubtitle {
                        Text(folder)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .truncationMode(.head)
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: ChromeMetrics.toolbarHeight)
    }
}
