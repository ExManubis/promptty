import SwiftUI
import WorkspaceModel

/// The floating glass sidebar: a header level with the traffic lights, then the tab list.
struct SidebarView: View {
    let state: WindowState
    let chrome: WindowChromeModel
    let actions: ChromeActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Spacer()
                ChromeIconButton(symbol: "sidebar.left", help: "Hide Sidebar", action: actions.toggleSidebar)
                ChromeIconButton(symbol: "plus", help: "New Tab", action: actions.newTab)
            }
            .padding(.leading, ChromeMetrics.trafficLightsWidth - ChromeMetrics.inset)
            .padding(.trailing, 8)
            .frame(height: ChromeMetrics.titlebarHeight - ChromeMetrics.inset)

            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabRow(tab: tab, index: index, selected: tab.id == state.selectedTabID, style: .full, chrome: chrome, actions: actions)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: ChromeMetrics.sidebarCornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

/// A small borderless SF Symbol button used in the chrome.
struct ChromeIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}
