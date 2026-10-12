import SwiftUI
import WorkspaceModel

/// The sidebar, flush with the window background like Dia's: a band for the traffic lights,
/// the tab rows, and a dim "+ New Tab" row.
struct SidebarView: View {
    let state: WindowState
    let chrome: WindowChromeModel
    let actions: ChromeActions
    /// Shown as a peek over the panes while the sidebar is collapsed.
    var collapsed = false

    var body: some View {
        VStack(spacing: 0) {
            // The traffic lights' band, with Dia's sidebar button just right of them. Peeking, the
            // panel is inset from the window's corner, so the band is narrower by the inset and
            // shorter by twice it: its midline stays on the traffic lights'.
            HStack(spacing: 0) {
                Color.clear.frame(width: ChromeMetrics.trafficLightsWidth - (collapsed ? ChromeMetrics.inset : 0))
                ChromeIconButton(symbol: "sidebar.left", help: collapsed ? "Keep Sidebar Open" : "Hide Sidebar", action: actions.toggleSidebar)
                Spacer(minLength: 0)
            }
            .frame(height: ChromeMetrics.titlebarHeight - (collapsed ? 2 * ChromeMetrics.inset : 0))
            // Above the tab list, whose scroll view reaches up under the titlebar and would take
            // the button's clicks.
            .zIndex(1)

            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    AgentsSection(actions: actions)
                    ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabRow(tab: tab, index: index, selected: tab.id == state.selectedTabID, style: .full, chrome: chrome, actions: actions)
                    }
                    NewTabRow(action: actions.newTab)
                }
                .padding(.horizontal, ChromeMetrics.sidebarHorizontalPadding)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

/// A small borderless SF Symbol button used in the chrome.
struct ChromeIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
