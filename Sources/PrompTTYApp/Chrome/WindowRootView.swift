import Preferences
import SwiftUI
import WorkspaceModel

/// Everything inside a terminal window, laid out like Dia: the window background, the tab list
/// (flush sidebar, strip, or hidden), and one rounded content panel holding the toolbar, banner
/// and every tab's pane tree (only the selected one visible).
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
                    panel(toolbarLeadingInset: ChromeMetrics.trafficLightsWidth - ChromeMetrics.inset)
                        .padding(ChromeMetrics.inset)
                } else if layout == .sidebar {
                    HStack(spacing: 0) {
                        SidebarView(state: state, chrome: chrome, actions: actions)
                            .frame(width: settings.settings.sidebarWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        panel(toolbarLeadingInset: 0)
                            .padding([.top, .bottom, .trailing], ChromeMetrics.inset)
                    }
                } else {
                    VStack(spacing: 0) {
                        TabStripView(state: state, chrome: chrome, actions: actions)
                            .frame(height: ChromeMetrics.titlebarHeight)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        panel(toolbarLeadingInset: 0)
                            .padding([.horizontal, .bottom], ChromeMetrics.inset)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1), value: layout)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.08), value: hidden)
        .environment(\.windowChrome, chrome)
    }

    /// The content panel, filled with the terminal theme's background so the toolbar and the
    /// terminal read as one surface. Its color scheme follows that fill, not the window.
    private func panel(toolbarLeadingInset: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.panelCornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            PanelToolbar(state: state, sidebarHidden: hidden, actions: actions)
                .padding(.leading, toolbarLeadingInset)
            if let banner = chrome.banner {
                BannerView(content: banner)
                    .id(banner.id)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
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
            .padding([.horizontal, .bottom], ChromeMetrics.paneInset)
            .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.06), value: state.selectedTab?.root)
        }
        .background {
            shape.fill(Color(nsColor: chrome.panelColor))
                .shadow(color: .black.opacity(chrome.panelIsDark ? 0.25 : 0.07), radius: 2.5, y: 1)
        }
        .overlay {
            shape.strokeBorder(Color.primary.opacity(chrome.panelIsDark ? 0.09 : 0.10), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, chrome.panelIsDark ? .dark : .light)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chrome.banner?.id)
    }
}
