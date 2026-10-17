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

    /// The tabs' own width, for the glass track to hug them (up to the room there is).
    @State private var tabsWidth: CGFloat = 0
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The glass thumb under the selected tab, as Safari's and Rex's: it slides to the next one.
    private var selectionThumb: some View {
        Capsule()
            .fill(Color.white.opacity(chrome.panelIsDark ? 0.14 : 0.75))
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(chrome.panelIsDark ? 0.35 : 0.9), Color.white.opacity(0.04)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .shadow(color: .black.opacity(chrome.panelIsDark ? 0.3 : 0.12), radius: 3, y: 1)
            .matchedGeometryEffect(id: "thumb", in: thumb)
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
            // The tabs in one Liquid Glass track, the selected one on a glass thumb that slides, as
            // Safari's and Rex's tab bars.
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                        let selected = tab.id == state.selectedTabID
                        if tab.pin != nil {
                            // Pinned tabs: icon-only pills first, as in a browser's tab strip.
                            TabRow(tab: tab, index: index, selected: selected, style: .tile, chrome: chrome, actions: actions)
                                .frame(width: 44, height: 28)
                        } else {
                            // No project headers here: a thin line where one project's tabs end.
                            if index > state.pinnedCount, state.project(of: state.tabs[index - 1]) != state.project(of: tab) {
                                Divider()
                                    .frame(height: 16)
                                    .padding(.horizontal, 4)
                            }
                            TabRow(tab: tab, index: index, selected: selected, style: .compact, chrome: chrome, actions: actions)
                                .frame(minWidth: 96, maxWidth: 220)
                                .background { if selected { selectionThumb } }
                        }
                    }
                }
                .padding(3)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
            }
            .scrollIndicators(.never)
            .frame(maxWidth: tabsWidth > 0 ? tabsWidth : nil)
            .glassEffect(.regular, in: Capsule())
            .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.18), value: state.selectedTabID)
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
