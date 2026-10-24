import PaneActivity
import PrompTTYChrome
import SwiftUI
import WorkspaceModel

/// One pane: its terminal in a rounded card, dimmed when another pane of a split tab has focus, and the
/// "process exited" panel.
struct PaneCard: View {
    let pane: Pane
    let tab: WorkspaceModel.Tab
    let visible: Bool
    /// This pane fills the tab.
    var zoomed = false
    /// Another pane is zoomed: this one is kept alive, occluded, at the size it had.
    var hidden = false
    let chrome: WindowChromeModel
    let actions: ChromeActions

    private var focused: Bool { tab.focusedPaneID == pane.id }
    private var broadcasting: Bool { chrome.broadcastTabs.contains(tab.id) }
    @Environment(\.paneHeaders) private var headerSetting
    @Environment(\.translucentPanes) private var translucent

    /// The card's surface. Opaque, the theme's background. See-through, Liquid Glass as Rex's panes
    /// look: tinted lightly toward the theme, so the wallpaper's color comes through rich rather
    /// than washed out, and the glass's own edges catch light and take on the color behind them.
    /// The focused pane of a split is tinted a little less, so it reads a touch brighter (Rex shows
    /// focus that way, dimming nothing).
    @ViewBuilder
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.paneCornerRadius, style: .continuous)
        if translucent, !visible {
            // A tab out of sight is drawn at no opacity, but its glass would still be rendered,
            // and again at every frame it changes size, as while the sidebar slides.
            Color.clear
        } else if translucent {
            let lit = focused || !tab.hasSplits
            Color.clear.glassEffect(.clear.tint(Color(nsColor: chrome.panelColor).opacity(Self.glassTint(dark: chrome.panelIsDark, lit: lit))), in: shape)
                // Smoked: a thin dark layer in the glass, so the desktop's color shows through the
                // pane, darkened, as through tinted glass (less theme color alone would let the
                // brighter desktop lighten the pane).
                .overlay(shape.fill(Color.black.opacity(Self.smoke(dark: chrome.panelIsDark, lit: lit))))
                // Rex's edges. The glass lights its own top and bottom edges: in dark, as bright along
                // the top as Rex's, and brighter along the bottom, so the bottom is shaded back down a
                // little. A faint line, added to the color under it so it keeps the hue, traces the
                // sides, which the glass leaves unlit. (Layers, so a card changing size redraws
                // nothing: see `PaneEdges`.)
                .overlay(PaneEdges(panelColor: chrome.panelColor, dark: chrome.panelIsDark, bottomShade: Self.bottomShade)
                    .allowsHitTesting(false))
        } else {
            shape.fill(Color(nsColor: chrome.panelColor))
        }
    }

    static var tintOverride: Double? {
        #if DEBUG
        ProcessInfo.processInfo.environment["PROMPTTY_GLASS_TINT"].flatMap(Double.init)
        #else
        nil
        #endif
    }

    static var bottomShade: Double {
        #if DEBUG
        ProcessInfo.processInfo.environment["PROMPTTY_GLASS_SHADE"].flatMap(Double.init) ?? 0.45
        #else
        0.45
        #endif
    }

    /// How dark the glass's smoke is; more on the unfocused panes of a split.
    static func smoke(dark: Bool, lit: Bool) -> Double {
        guard dark else { return 0 }
        let base = debugValue("PROMPTTY_GLASS_SMOKE") ?? 0.35
        let dim = debugValue("PROMPTTY_GLASS_SMOKE_DIM") ?? 0.08
        return lit ? base : base + dim
    }

    private static func debugValue(_ name: String) -> Double? {
        #if DEBUG
        ProcessInfo.processInfo.environment[name].flatMap(Double.init)
        #else
        nil
        #endif
    }

    /// How much of the theme's background tints the glass.
    static func glassTint(dark: Bool, lit: Bool) -> Double {
        let base = tintOverride ?? (dark ? 0.16 : 0.28)
        #if DEBUG
        let dim = ProcessInfo.processInfo.environment["PROMPTTY_GLASS_DIM"].flatMap(Double.init) ?? (dark ? 0 : 0.08)
        #else
        let dim = dark ? 0 : 0.08
        #endif
        return lit ? base : base + dim
    }

    /// The card's edge: opaque cards keep a plain hairline.
    private var rim: AnyShapeStyle {
        guard translucent else { return AnyShapeStyle(Color.primary.opacity(borderOpacity)) }
        // The glass draws its own edge (see `surface`); only the focused pane of a split gets a
        // faint line more.
        return AnyShapeStyle(Color.white.opacity(focused && tab.hasSplits ? 0.10 : 0))
    }

    private var showsHeader: Bool {
        switch headerSetting {
        case .always: true
        case .splits: tab.hasSplits
        case .never: false
        }
    }

    /// A hairline edge; in a split tab the focused pane's edge is brighter so it stands out.
    private var borderOpacity: Double {
        guard tab.hasSplits, focused else { return 0.08 }
        return chrome.panelIsDark ? 0.24 : 0.22
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if showsHeader {
                    PaneHeader(pane: pane, tab: tab, focused: focused, zoomed: zoomed, chrome: chrome, actions: actions)
                }
                if let surface = actions.surfaceView(for: pane) {
                    PaneHost(surface: surface, visible: visible, holdSize: hidden)
                }
                if let shell = actions.shell(for: pane.id), shell.bar != .hidden {
                    InputBarView(shell: shell, dark: chrome.panelIsDark)
                        .transition(.opacity)
                }
            }

            // Dia-style focus: the other panes fade slightly toward the panel color, in the
            // card's own shape so the dimming stays inside its rounded corners.
            RoundedRectangle(cornerRadius: ChromeMetrics.paneCornerRadius, style: .continuous)
                .fill(Color(nsColor: chrome.panelColor).opacity(0.38))
                .opacity(tab.hasSplits && !focused && !translucent ? 1 : 0)
                .animation(PaneAnimation.focusFade, value: focused)
                .allowsHitTesting(false)

            // Over the terminal, below the header (which shows the label and the zoom itself).
            Group {
                ClipboardBanner(pane: pane.id, actions: actions)
                LinkPreview(pane: pane.id, actions: actions)
                SecureLock(pane: pane.id, actions: actions)
                FindBar(pane: pane.id, actions: actions)
                if !showsHeader, let label = pane.label, actions.findState(for: pane.id) == nil {
                    PaneLabelChip(label: label, besideBadge: actions.isSecure(pane.id))
                }
                if zoomed, !showsHeader { ZoomBadge() }
                if broadcasting { BroadcastBadge() }
                RemoteBadge(pane: pane.id, actions: actions)
            }
            .padding(.top, showsHeader ? PaneHeader.height : 0)

            if let code = chrome.exitedPanes[pane.id] {
                // A pinned tab's last pane is restarted, not closed.
                ExitedOverlay(exitCode: code, restarts: tab.pin != nil && !tab.hasSplits) { actions.requestClosePane(pane.id) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            // The card: the terminal theme's color, a hairline edge and a soft shadow, so each
            // pane stands apart from the window background and from its neighbours.
            surface
                .shadow(color: .black.opacity(chrome.panelIsDark ? (translucent ? 0.22 : 0.25) : (translucent ? 0.06 : 0.08)),
                        radius: translucent ? 8 : 2.5, y: translucent ? 2 : 1)
                .animation(PaneAnimation.focusFade, value: focused)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ChromeMetrics.paneCornerRadius, style: .continuous)
                .strokeBorder(broadcasting ? AnyShapeStyle(Color.orange.opacity(focused ? 0.95 : 0.6)) : rim,
                              lineWidth: broadcasting ? 2 : (translucent ? 0.75 : 1))
                .animation(PaneAnimation.focusFade, value: borderOpacity)
                .animation(PaneAnimation.focusFade, value: broadcasting)
                .allowsHitTesting(false)
        }
        // ⌘C: the card catches the light, as Rex's code cards do when copied.
        .overlay { CopyShineOverlay(trigger: chrome.copyShines[pane.id] ?? 0, cornerRadius: ChromeMetrics.paneCornerRadius) }
        .environment(\.colorScheme, chrome.panelIsDark ? .dark : .light)
        .modifier(PaneDropTarget(pane: pane, chrome: chrome, actions: actions))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pane.title.isEmpty ? "Terminal" : pane.title)
    }
}

/// What a pane is called: the program's own title (Claude Code's session, the file nvim edits),
/// else the program's name, else the folder.
@MainActor
enum PaneTitle {
    static func title(pane: Pane, program: Program?, folder: String) -> String {
        let own = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty, own != folder, own != pane.workingDirectory { return own }
        return program?.name ?? folder
    }

    /// What a pane header or a strip pill shows: the title, and the folder beside it unless the
    /// title is the folder. A shell at its prompt says which shell ("zsh ~/api"), as Rex's do.
    static func titleAndFolder(pane: Pane, program: Program?, customTitle: String? = nil) -> (title: String, folder: String?) {
        let folder = WorkspaceModel.Tab.abbreviate(pane.workingDirectory)
        if let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return (custom, folder) }
        let named = title(pane: pane, program: program, folder: folder)
        if named == folder { return program == nil ? (shellName, folder) : (named, nil) }
        return (named, folder)
    }

    static let shellName: String = {
        let name = (ShellIntegration.loginShell as NSString).lastPathComponent
        return name.isEmpty ? "Shell" : name
    }()
}

/// Shown over a pane whose shell has exited.
struct ExitedOverlay: View {
    let exitCode: UInt32
    var restarts = false
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: exitCode == 0 ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(exitCode == 0 ? Color.secondary : Color.orange)
            Text(exitCode == 0 ? "Process exited" : "Process exited with code \(exitCode)")
                .font(.system(size: 13, weight: .medium))
            Button(restarts ? "Restart" : "Close", action: onClose)
                .controlSize(.regular)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(FlatSurface(cornerRadius: 12))
    }
}

/// The link under the pointer, at the pane's bottom-left like a browser's status bar. Its own view,
/// so the hover changes redraw only this.
private struct LinkPreview: View {
    let pane: PaneID
    let actions: ChromeActions

    var body: some View {
        if let link = actions.hoveredLink(for: pane) {
            Text(link)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(false)
        }
    }
}

/// "<program> wants to read the clipboard", over the pane's top edge until the user answers. Its
/// own view, so only this redraws when a request comes or goes.
private struct ClipboardBanner: View {
    let pane: PaneID
    let actions: ChromeActions
    /// The request whose buttons work: they do only a moment after it appears, so a click meant
    /// for the one before cannot land on the one now shown.
    @State private var armedID: Int?

    var body: some View {
        if let ticket = actions.clipboardRequest(for: pane) {
            let program = actions.activity(for: pane).program
            let action = ticket.kind == .read ? "read" : "write to"
            // A known program is allowed for good wherever it runs; an unknown one in this pane.
            let always: (String, () -> Void) = if let program {
                ("Always allow for \(program.name)", { actions.alwaysAllowClipboard(ticket, for: program.id, in: pane) })
            } else {
                ("Always allow for this pane", { actions.answerClipboardRequest(.alwaysAllow, id: ticket.id, in: pane) })
            }
            BannerView(content: BannerContent(
                message: "\(program?.name ?? "A program") wants to \(action) the clipboard",
                actionTitle: "Allow",
                action: { actions.answerClipboardRequest(.allow, id: ticket.id, in: pane) },
                symbol: "doc.on.clipboard",
                extraActions: [
                    always,
                    ("Deny", { actions.answerClipboardRequest(.deny, id: ticket.id, in: pane) }),
                ]
            ))
            .disabled(armedID != ticket.id)
            .task(id: ticket.id) {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { armedID = ticket.id }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// A lock at the pane's top-right while secure keyboard input is on for it. Its own view, so only
/// this redraws when that changes.
private struct SecureLock: View {
    let pane: PaneID
    let actions: ChromeActions

    var body: some View {
        if actions.isSecure(pane) {
            PaneBadge(symbol: "lock.fill", help: "Secure keyboard entry is on", alignment: .topTrailing)
        }
    }
}

/// While remote clients mirror the pane: who, at its bottom right; while it has a device's size
/// (the terminal letterboxed to the device's grid, it was used there last), which.
private struct RemoteBadge: View {
    let pane: PaneID
    let actions: ChromeActions

    var body: some View {
        if let remote = actions.remote(for: pane) {
            Label(remote.text, systemImage: remote.sizedBy == nil ? "iphone" : "iphone.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((remote.sizedBy == nil ? Color.blue : Color.orange).opacity(0.85), in: Capsule())
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
                .help(remote.help)
                .accessibilityLabel(remote.text)
        }
    }
}

/// While input is broadcast to every pane of the tab: a label at the top of each pane, so it is
/// never on unnoticed.
private struct BroadcastBadge: View {
    var body: some View {
        Label("Broadcasting", systemImage: "dot.radiowaves.left.and.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.9), in: Capsule())
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .help("Input goes to every pane of this tab. Turn it off in Window › Broadcast Input to All Panes.")
            .accessibilityLabel("Broadcasting input to all panes")
    }
}

/// A pane's label, at its top-right, where output lines seldom reach (left of the lock badge when
/// that shows; hidden while the find bar is there).
private struct PaneLabelChip: View {
    let label: String
    let besideBadge: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassEffect(.regular, in: Capsule())
            .padding(.trailing, besideBadge ? 40 : 8)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
            .accessibilityLabel("Pane label: \(label)")
    }
}

/// Marks the zoomed pane, at its top-left.
private struct ZoomBadge: View {
    var body: some View {
        PaneBadge(symbol: "arrow.up.left.and.arrow.down.right", help: "Zoomed. Press the zoom shortcut again to show all panes.", alignment: .topLeading)
            .accessibilityLabel("Zoomed pane")
    }
}

/// A small round mark in a corner of the pane.
private struct PaneBadge: View {
    let symbol: String
    let help: String
    let alignment: Alignment

    var body: some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(5)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .help(help)
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}
