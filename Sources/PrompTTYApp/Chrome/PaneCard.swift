import PaneActivity
import SwiftUI
import WorkspaceModel

/// One pane: its terminal in a rounded card, dimmed when another pane of a split tab has focus, a header that
/// appears when the pointer nears the top edge, and the "process exited" panel.
struct PaneCard: View {
    let pane: Pane
    let tab: WorkspaceModel.Tab
    let visible: Bool
    let chrome: WindowChromeModel
    let actions: ChromeActions

    @State private var pointerNearTop = false
    @State private var pointerOverHeader = false

    private var focused: Bool { tab.focusedPaneID == pane.id }

    /// A hairline edge; in a split tab the focused pane's edge is brighter so it stands out.
    private var borderOpacity: Double {
        guard tab.hasSplits, focused else { return 0.10 }
        return chrome.panelIsDark ? 0.35 : 0.30
    }
    private var showHeader: Bool { visible && (pointerNearTop || pointerOverHeader || chrome.forceHeaders) }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if let surface = actions.surfaceView(for: pane) {
                    PaneHost(surface: surface, visible: visible)
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
                .opacity(tab.hasSplits && !focused ? 1 : 0)
                .animation(PaneAnimation.focusFade, value: focused)
                .allowsHitTesting(false)

            if let code = chrome.exitedPanes[pane.id] {
                ExitedOverlay(exitCode: code) { actions.requestClosePane(pane.id) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showHeader {
                PaneHeader(pane: pane, tab: tab, actions: actions)
                    .onHover { pointerOverHeader = $0 }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            // The card: the terminal theme's color, a hairline edge and a soft shadow, so each
            // pane stands apart from the window background and from its neighbours.
            let shape = RoundedRectangle(cornerRadius: ChromeMetrics.paneCornerRadius, style: .continuous)
            shape.fill(Color(nsColor: chrome.panelColor))
                .shadow(color: .black.opacity(chrome.panelIsDark ? 0.25 : 0.08), radius: 2.5, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ChromeMetrics.paneCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 1)
                .animation(PaneAnimation.focusFade, value: borderOpacity)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, chrome.panelIsDark ? .dark : .light)
        .modifier(PaneDropTarget(pane: pane, chrome: chrome, actions: actions))
        .animation(.easeOut(duration: 0.15), value: showHeader)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location): pointerNearTop = location.y < 34
            case .ended: pointerNearTop = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pane.title.isEmpty ? "Terminal" : pane.title)
    }
}

/// Flat bar along a pane's top edge, shown on hover: drag handle, the program running and its
/// title, the folder, the pane's activity, split and close buttons.
struct PaneHeader: View {
    let pane: Pane
    let tab: WorkspaceModel.Tab
    let actions: ChromeActions

    var body: some View {
        let activity = actions.activity(for: pane.id)
        let folder = WorkspaceModel.Tab.abbreviate(pane.workingDirectory)
        let title = Self.title(pane: pane, program: activity.program, folder: folder)
        HStack(spacing: 6) {
            PaneDragHandle(pane: pane)
            ProgramIcon(program: activity.program, size: 13)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if title != folder {
                Text(folder)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            ActivityIndicator(display: activity.display)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                HeaderButton(symbol: "rectangle.split.2x1", help: "Split Right") { actions.split(pane.id, direction: .right) }
                HeaderButton(symbol: "rectangle.split.1x2", help: "Split Down") { actions.split(pane.id, direction: .down) }
                HeaderButton(symbol: "xmark", help: tab.hasSplits ? "Close Pane" : "Close Tab") { actions.requestClosePane(pane.id) }
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(FlatSurface(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    /// The program's own title (Claude Code's session, the file nvim edits), else the program's
    /// name, else the folder.
    static func title(pane: Pane, program: Program?, folder: String) -> String {
        let own = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty, own != folder, own != pane.workingDirectory { return own }
        return program?.name ?? folder
    }
}

struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Shown over a pane whose shell has exited.
struct ExitedOverlay: View {
    let exitCode: UInt32
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: exitCode == 0 ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(exitCode == 0 ? Color.secondary : Color.orange)
            Text(exitCode == 0 ? "Process exited" : "Process exited with code \(exitCode)")
                .font(.system(size: 13, weight: .medium))
            Button("Close", action: onClose)
                .controlSize(.regular)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(FlatSurface(cornerRadius: 12))
    }
}

/// A flat raised surface (Dia's popovers and bars): solid fill, hairline border, soft shadow.
struct FlatSurface: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(colorScheme == .dark ? Color(white: 0.17) : Color.white)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 4, y: 1)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
    }
}
