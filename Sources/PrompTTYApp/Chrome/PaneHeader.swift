import PaneActivity
import Preferences
import PrompTTYChrome
import SwiftUI
import WorkspaceModel

/// A pane's header, as Rex draws one: the top of the pane itself (no band, no rule), its program as
/// a one-color glyph, its title and folder (and label); split, zoom and close at the right, on the
/// focused pane and under the pointer. Dragging it moves the pane.
struct PaneHeader: View {
    let pane: Pane
    let tab: WorkspaceModel.Tab
    let focused: Bool
    let zoomed: Bool
    let chrome: WindowChromeModel
    let actions: ChromeActions
    @State private var hovering = false

    static let height: CGFloat = 28

    var body: some View {
        // Read here: only the header redraws as the program changes.
        let activity = actions.activity(for: pane.id)
        let (title, folder) = PaneTitle.titleAndFolder(pane: pane, program: activity.program)
        let lit = focused || !tab.hasSplits
        HStack(spacing: 8) {
            ProgramIcon(program: activity.program, size: 13, fallbackSymbol: "apple.terminal",
                        tint: Color.primary.opacity(lit ? 0.75 : 0.5), monochrome: true)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(lit ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let folder {
                Text(folder)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let label = pane.label {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.09), in: Capsule())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            let ports = actions.ports(for: pane.id)
            if !ports.isEmpty {
                ForEach(ports.prefix(2), id: \.self) { port in
                    Button(":\(String(port))") { actions.openPort(port) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                        .help("Open localhost:\(String(port))")
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                HeaderButton(symbol: "rectangle.split.2x1", help: "Split Right") { actions.split(pane.id, direction: .right) }
                HeaderButton(symbol: "rectangle.split.1x2", help: "Split Down") { actions.split(pane.id, direction: .down) }
                if tab.hasSplits {
                    HeaderButton(symbol: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                 help: zoomed ? "Unzoom Pane" : "Zoom Pane") { actions.toggleZoom(pane.id) }
                }
                HeaderButton(symbol: "xmark", help: "Close Pane") { actions.requestClosePane(pane.id) }
            }
            .foregroundStyle(.secondary)
            .opacity(focused && tab.hasSplits || hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { actions.focusPane(pane.id) }
        .onDrag {
            chrome.beginPaneDrag(pane.id)
            return DragPayload.provider(DragPayload.pane, id: pane.id.rawValue)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel([title, pane.label, folder].compactMap { $0 }.joined(separator: ", "))
    }
}

/// When panes show their header (Settings › Appearance).
private struct PaneHeadersKey: EnvironmentKey {
    static let defaultValue = PaneHeaders.always
}

extension EnvironmentValues {
    var paneHeaders: PaneHeaders {
        get { self[PaneHeadersKey.self] }
        set { self[PaneHeadersKey.self] = newValue }
    }
}

/// Whether panes are see-through (Settings › Appearance).
private struct TranslucentPanesKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var translucentPanes: Bool {
        get { self[TranslucentPanesKey.self] }
        set { self[TranslucentPanesKey.self] = newValue }
    }
}
