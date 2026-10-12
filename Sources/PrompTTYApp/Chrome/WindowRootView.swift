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
    @State private var tabFade = TabFadeState()
    /// The collapsed sidebar, shown over the panes while the pointer is on it.
    @State private var peeking = false
    @State private var peekTimer: Task<Void, Never>?

    private var hidden: Bool { settings.settings.tabListHidden }
    private var layout: TabLayout { workspace.tabLayout }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WindowBackdrop(tint: chrome.tint)

            Group {
                if hidden, layout == .sidebar {
                    collapsedSidebar
                } else if hidden {
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
        .onChange(of: hidden) { _, _ in peeking = false }
        .environment(\.windowChrome, chrome)
    }

    /// Dia's collapsed sidebar: the panes take the window below a thin band holding the traffic
    /// lights and the sidebar button; the sidebar peeks in over them from the left edge.
    private var collapsedSidebar: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: ChromeMetrics.collapsedTrafficLightsWidth)
                    ChromeIconButton(symbol: "sidebar.left", help: "Show Sidebar", action: actions.toggleSidebar)
                    Spacer(minLength: 0)
                }
                .frame(height: ChromeMetrics.collapsedBandHeight)
                paneArea
                    .padding([.horizontal, .bottom], ChromeMetrics.inset)
            }

            // Resting at the left edge peeks the sidebar in.
            Color.clear
                .frame(width: ChromeMetrics.peekEdgeWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { inside in setPeek(inside, after: .milliseconds(150)) }
                .accessibilityHidden(true)

            if peeking || chrome.forcedPeek {
                SidebarView(state: state, chrome: chrome, actions: actions, collapsed: true)
                    .frame(width: settings.settings.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    // Lifted off the panes it floats over.
                    .shadow(color: .black.opacity(0.35), radius: 14, x: 4)
                    .padding([.vertical, .leading], ChromeMetrics.inset)
                    .onHover { inside in setPeek(inside, after: .milliseconds(inside ? 0 : 250)) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.08), value: peeking)
    }

    /// Peeks the collapsed sidebar in or out after a moment, so a pointer passing the edge (or
    /// leaving the peek for an instant) does not flicker it.
    private func setPeek(_ show: Bool, after delay: Duration) {
        peekTimer?.cancel()
        peekTimer = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            peeking = show
        }
    }

    private var paneArea: some View {
        VStack(spacing: ChromeMetrics.paneGap) {
            if let banner = chrome.banner {
                BannerView(content: banner)
                    .id(banner.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            let generation = tabFade.update(selected: state.selectedTabID, tabs: state.tabs.map(\.id), animate: !reduceMotion)
            ZStack {
                ForEach(state.tabs, id: \.id) { tab in
                    TabPanes(tab: tab, selected: tab.id == state.selectedTabID, outgoing: tab.id == tabFade.outgoing,
                             chrome: chrome, actions: actions)
                }
            }
            .keyframeAnimator(initialValue: CGFloat(1), trigger: generation) { content, progress in
                content.environment(\.tabFadeProgress, progress)
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: PaneAnimation.tabDuration, timingCurve: PaneAnimation.tabCurve)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chrome.banner?.id)
    }
}
