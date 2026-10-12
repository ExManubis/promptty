import SwiftUI
import WorkspaceModel

/// Horizontal tabs as glass capsules in the titlebar band, right of the traffic lights.
struct TabStripView: View {
    let state: WindowState
    let chrome: WindowChromeModel
    let actions: ChromeActions

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                            let selected = tab.id == state.selectedTabID
                            TabRow(tab: tab, index: index, selected: selected, style: .compact, chrome: chrome, actions: actions)
                                .frame(minWidth: 110, idealWidth: 180, maxWidth: 220)
                                .glassEffect(selected ? .regular.tint(Color.accentColor.opacity(0.18)) : .regular, in: .capsule)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollIndicators(.never)
            ChromeIconButton(symbol: "plus", help: "New Tab", action: actions.newTab)
        }
        .padding(.leading, ChromeMetrics.trafficLightsWidth + 8)
        .padding(.trailing, ChromeMetrics.inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

/// Titlebar band when the tab list is hidden: a way back to the sidebar, the title, new tab.
struct CompactTitleBar: View {
    let state: WindowState
    let actions: ChromeActions

    var body: some View {
        HStack(spacing: 2) {
            ChromeIconButton(symbol: "sidebar.left", help: "Show Tabs", action: actions.toggleSidebar)
            Spacer()
            Text(state.selectedTab?.listTitle ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            ChromeIconButton(symbol: "plus", help: "New Tab", action: actions.newTab)
        }
        .padding(.leading, ChromeMetrics.trafficLightsWidth)
        .padding(.trailing, ChromeMetrics.inset)
    }
}
