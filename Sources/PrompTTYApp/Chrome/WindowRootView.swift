import Preferences
import SwiftUI
import WorkspaceModel

/// Everything inside a terminal window: the window background, the tab list (flush sidebar,
/// strip, or hidden), the banner, and every tab's pane tree (only the selected one visible).
/// Each pane is its own rounded card, separated by gaps that show the window background.
struct WindowRootView: View {
    let state: WindowState
    let workspace: Workspace
    let settings: SettingsModel
    let chrome: WindowChromeModel
    let actions: ChromeActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tabSlide = TabSlideState()

    private var hidden: Bool { settings.settings.tabListHidden }
    private var layout: TabLayout { workspace.tabLayout }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WindowBackdrop(tint: chrome.tint)

            Group {
                if hidden {
                    VStack(spacing: 0) {
                        CompactTitleBar(state: state, actions: actions)
                            .frame(height: ChromeMetrics.titlebarHeight)
                        paneArea
                            .padding([.horizontal, .bottom], ChromeMetrics.inset)
                    }
                } else if layout == .sidebar {
                    HStack(spacing: 0) {
                        SidebarView(state: state, chrome: chrome, actions: actions)
                            .frame(width: settings.settings.sidebarWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        paneArea
                            .padding([.top, .bottom, .trailing], ChromeMetrics.inset)
                    }
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
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1), value: layout)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.08), value: hidden)
        .environment(\.windowChrome, chrome)
    }

    private var paneArea: some View {
        VStack(spacing: ChromeMetrics.paneGap) {
            if let banner = chrome.banner {
                BannerView(content: banner)
                    .id(banner.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            GeometryReader { geo in
                let generation = tabSlide.update(selected: state.selectedTabID, order: state.tabs.map(\.id), animate: !reduceMotion)
                ZStack {
                    ForEach(state.tabs, id: \.id) { tab in
                        TabPanes(tab: tab, selected: tab.id == state.selectedTabID, outgoing: tab.id == tabSlide.outgoing,
                                 direction: tabSlide.direction, shift: slideShift(in: geo.size), chrome: chrome, actions: actions)
                    }
                }
                .keyframeAnimator(initialValue: CGFloat(1), trigger: generation) { content, progress in
                    content.environment(\.tabSlideProgress, progress)
                } keyframes: { _ in
                    KeyframeTrack {
                        MoveKeyframe(0)
                        LinearKeyframe(1, duration: PaneAnimation.tabDuration, timingCurve: PaneAnimation.tabCurve)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chrome.banner?.id)
    }

    /// A tab slides a whole pane area: down the sidebar's list vertically, along a strip sideways.
    private func slideShift(in size: CGSize) -> CGSize {
        let vertical = !hidden && layout == .sidebar
        return vertical
            ? CGSize(width: 0, height: size.height + ChromeMetrics.paneGap)
            : CGSize(width: size.width + ChromeMetrics.paneGap, height: 0)
    }
}
