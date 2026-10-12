import Preferences
import SwiftUI
import WorkspaceModel

/// Everything inside a terminal window: tinted backdrop, the tab list (sidebar, strip, or hidden),
/// the banner, and every tab's pane tree (only the selected one visible).
struct WindowRootView: View {
    let state: WindowState
    let workspace: Workspace
    let settings: SettingsModel
    let chrome: WindowChromeModel
    let actions: ChromeActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hidden: Bool { settings.settings.tabListHidden }
    private var layout: TabLayout { workspace.tabLayout }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: chrome.tint)

            Group {
                if hidden {
                    VStack(spacing: 0) {
                        CompactTitleBar(state: state, actions: actions)
                            .frame(height: ChromeMetrics.titlebarHeight)
                        paneArea
                            .padding([.horizontal, .bottom], ChromeMetrics.inset)
                    }
                } else if layout == .sidebar {
                    HStack(spacing: ChromeMetrics.sidebarGap) {
                        SidebarView(state: state, chrome: chrome, actions: actions)
                            .frame(width: settings.settings.sidebarWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        paneArea
                    }
                    .padding(ChromeMetrics.inset)
                } else {
                    VStack(spacing: 0) {
                        TabStripView(state: state, chrome: chrome, actions: actions)
                            .frame(height: ChromeMetrics.titlebarHeight)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        paneArea
                            .padding([.horizontal, .bottom], ChromeMetrics.inset)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.12), value: layout)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1), value: hidden)
        .environment(\.windowChrome, chrome)
    }

    private var paneArea: some View {
        VStack(spacing: 6) {
            if let banner = chrome.banner {
                BannerView(content: banner)
                    .id(banner.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ZStack {
                ForEach(state.tabs, id: \.id) { tab in
                    let visible = tab.id == state.selectedTabID
                    PaneTreeView(node: tab.root, path: SplitPath(steps: []), tab: tab, visible: visible, chrome: chrome, actions: actions)
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(visible)
                        .accessibilityHidden(!visible)
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.08), value: state.selectedTab?.root)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chrome.banner?.id)
    }
}
