import PaneActivity
import Preferences
import SwiftUI
import WorkspaceModel

/// A pane's header, as Rex draws one: its program, title and folder (and label) on a slightly
/// lighter band; split, zoom and close at the right, on the focused pane and under the pointer.
/// Dragging it moves the pane.
struct PaneHeader: View {
    let pane: Pane
    let tab: WorkspaceModel.Tab
    let focused: Bool
    let zoomed: Bool
    let chrome: WindowChromeModel
    let actions: ChromeActions
    @State private var hovering = false

    static let height: CGFloat = 30
    private static let shellName = (ShellIntegration.loginShell as NSString).lastPathComponent.nilIfEmpty ?? "Shell"

    var body: some View {
        // Read here: only the header redraws as the program changes.
        let activity = actions.activity(for: pane.id)
        let folder = WorkspaceModel.Tab.abbreviate(pane.workingDirectory)
        let named = PaneTitle.title(pane: pane, program: activity.program, folder: folder)
        // A shell at its prompt says which shell, with the folder beside it ("zsh ~/api"), as Rex's do.
        let title = named == folder && activity.program == nil ? Self.shellName : named
        let lit = focused || !tab.hasSplits
        HStack(spacing: 8) {
            ProgramTile(program: activity.program)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(lit ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if title != folder {
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
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: Self.height)
        .background(Color.primary.opacity(lit ? 0.055 : 0.025))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { actions.focusPane(pane.id) }
        .onDrag {
            chrome.beginPaneDrag(pane.id)
            return DragPayload.provider(DragPayload.pane, id: pane.id.rawValue)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel([title, pane.label, folder == title ? nil : folder].compactMap { $0 }.joined(separator: ", "))
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
