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
    /// The tab fade that has finished.
    @State private var fadeSettled = 0
    /// The collapsed sidebar, shown over the panes while the pointer is on it.
    @State private var peeking = false
    @State private var peekTimer: Task<Void, Never>?
    /// The terminals keep their sizes while the sidebar slides (see `holdTerminalSizes`).
    @State private var terminalSizesHeld = false
    @State private var terminalSizesRelease: Task<Void, Never>?
    /// The collapsed sidebar has slid out: its rows leave the hierarchy, so they stop observing
    /// the panes and animating out of sight. Expanding puts them back at once, to slide in.
    @State private var sidebarSettledAway = false

    private var hidden: Bool { settings.settings.tabListHidden }
    private var layout: TabLayout { workspace.tabLayout }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WindowBackdrop(tint: chrome.tint)

            Group {
                if layout == .sidebar {
                    sidebarLayout
                } else if hidden {
                    VStack(spacing: 0) {
                        CompactTitleBar(state: state, actions: actions)
                            .frame(height: ChromeMetrics.titlebarHeight)
                        paneArea
                            .padding([.horizontal, .bottom], ChromeMetrics.inset)
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

            CommandPaletteOverlay(chrome: chrome, actions: actions)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.1), value: layout)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: chrome.palette == nil)
        // Kept open from a peek, the sidebar is already there: it stays put instead of sliding
        // in again.
        .animation(sidebarAnimates ? .spring(PaneAnimation.sidebarSpring) : nil, value: hidden)
        .onChange(of: hidden) { _, _ in
            if sidebarAnimates { holdTerminalSizes() }
            peeking = false
        }
        .onChange(of: trafficLightsShown, initial: true) { _, shown in actions.setTrafficLightsShown(shown) }
        .environment(\.terminalResizeMode, terminalSizesHeld ? .held : chrome.resizingSplit ? .throttled : .live)
        .environment(\.windowChrome, chrome)
        .environment(\.paneHeaders, settings.settings.paneHeaders)
        .environment(\.translucentPanes, settings.settings.translucentPanes)
    }

    /// The sidebar beside the panes. Collapsing slides it out to the left while the panes widen
    /// into its place (one layout throughout, so the change animates); collapsed, the traffic
    /// lights and the sidebar button go with it, and it peeks in over the panes from the left
    /// edge.
    private var sidebarLayout: some View {
        let collapsed = hidden
        let width = settings.settings.sidebarWidth
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Group {
                    if !collapsed || !sidebarSettledAway {
                        SidebarView(state: state, workspace: workspace, chrome: chrome, actions: actions)
                            // Put back as the sidebar opens: it slides in with its frame.
                            .transition(.move(edge: .leading))
                    } else {
                        Color.clear
                    }
                }
                    .frame(width: width)
                    // Narrowing to nothing with the sidebar pinned to its trailing edge: it slides
                    // out to the left.
                    .frame(width: collapsed ? 0 : width, alignment: .trailing)
                    .clipped()
                    .opacity(collapsed ? 0 : 1)
                    .environment(\.sidebarOutOfSight, collapsed)
                    .allowsHitTesting(!collapsed)
                    .accessibilityHidden(collapsed)
                paneArea
                    .padding(.leading, collapsed ? ChromeMetrics.inset : 0)
                    .padding([.top, .bottom, .trailing], ChromeMetrics.inset)
            }

            if collapsed {
                // Resting at the left edge peeks the sidebar in.
                Color.clear
                    .frame(width: ChromeMetrics.peekEdgeWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in setPeek(inside, after: .milliseconds(150)) }
                    .accessibilityHidden(true)
            }

            if collapsed, showsPeek {
                SidebarView(state: state, workspace: workspace, chrome: chrome, actions: actions, collapsed: true)
                    .frame(width: width)
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
        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.08), value: showsPeek)
        .task(id: hidden) {
            guard hidden else {
                sidebarSettledAway = false
                return
            }
            try? await Task.sleep(for: .seconds(PaneAnimation.sidebarSpring.settlingDuration))
            if !Task.isCancelled { sidebarSettledAway = true }
        }
    }

    /// Also while a tab is renamed from it, or its icon changed: a tile's popover takes the pointer
    /// off it.
    private var showsPeek: Bool {
        peeking || chrome.forcedPeek || (hidden && (chrome.renamingTab != nil || chrome.iconPickerTab != nil))
    }

    /// The traffic lights belong to the sidebar: hidden while it is collapsed, back while it peeks.
    private var trafficLightsShown: Bool {
        !(hidden && layout == .sidebar) || showsPeek
    }

    private var sidebarAnimates: Bool { !reduceMotion && !showsPeek }

    /// The cards resize with the sliding sidebar every frame, but their terminals keep their sizes
    /// (drawn from the top-left, clipped or with a margin at the right) until it settles, then take
    /// the final one: each resize reflows the shell's screen, too much work for every frame.
    private func holdTerminalSizes() {
        terminalSizesHeld = true
        terminalSizesRelease?.cancel()
        terminalSizesRelease = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PaneAnimation.sidebarSpring.settlingDuration))
            guard !Task.isCancelled else { return }
            terminalSizesHeld = false
        }
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
            let fading = generation != fadeSettled
            ZStack {
                ForEach(state.tabs, id: \.id) { tab in
                    TabPanes(tab: tab, selected: tab.id == state.selectedTabID, outgoing: fading && tab.id == tabFade.outgoing,
                             fadeGeneration: generation, chrome: chrome, actions: actions)
                }
            }
            // The old tab is let go (hidden, its terminals occluded) once it has faded out.
            .task(id: generation) {
                try? await Task.sleep(for: .seconds(PaneAnimation.tabDuration))
                if !Task.isCancelled { fadeSettled = generation }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: chrome.banner?.id)
    }
}
