import SwiftUI
import WorkspaceModel

/// One pane: its terminal in a rounded card, a focus ring when the tab is split, a header that
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
    private var showHeader: Bool { visible && (pointerNearTop || pointerOverHeader || chrome.forceHeaders) }

    var body: some View {
        ZStack(alignment: .top) {
            PaneHost(surface: actions.surfaceView(for: pane), visible: visible)

            if tab.hasSplits {
                if focused {
                    RoundedRectangle(cornerRadius: ChromeMetrics.paneCornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                        .allowsHitTesting(false)
                } else {
                    RoundedRectangle(cornerRadius: ChromeMetrics.paneCornerRadius, style: .continuous)
                        .fill(Color(nsColor: chrome.tint).opacity(0.15))
                        .allowsHitTesting(false)
                }
            }

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

/// Glass capsule along a pane's top edge: drag handle, split and close buttons.
struct PaneHeader: View {
    let pane: Pane
    let tab: WorkspaceModel.Tab
    let actions: ChromeActions

    var body: some View {
        HStack(spacing: 2) {
            PaneDragHandle(pane: pane)
            Text(WorkspaceModel.Tab.abbreviate(pane.workingDirectory))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.trailing, 4)
            Spacer(minLength: 4)
            HeaderButton(symbol: "rectangle.split.2x1", help: "Split Right") { actions.split(pane.id, direction: .right) }
            HeaderButton(symbol: "rectangle.split.1x2", help: "Split Down") { actions.split(pane.id, direction: .down) }
            HeaderButton(symbol: "xmark", help: tab.hasSplits ? "Close Pane" : "Close Tab") { actions.requestClosePane(pane.id) }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 8)
        .padding(.top, 6)
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
                .buttonStyle(.glass)
                .controlSize(.regular)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
