import PaneActivity
import SwiftUI
import WorkspaceModel

/// A tab in miniature, shown beside the sidebar while the pointer rests on its row: its split
/// layout, each pane's last lines in the terminal's colors, its program and activity. Text, not
/// pixels: a hidden tab is not drawn, and stays live this way.
struct TabPreview: View {
    let tab: WorkspaceModel.Tab
    let actions: ChromeActions
    let panel: NSColor

    static let size = CGSize(width: 380, height: 236)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            PreviewNode(node: tab.root, tab: tab, actions: actions, panel: panel)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .padding(6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of \(tab.listTitle)")
    }
}

private struct PreviewNode: View {
    let node: SplitNode
    let tab: WorkspaceModel.Tab
    let actions: ChromeActions
    let panel: NSColor

    var body: some View {
        switch node {
        case .leaf(let id):
            if let pane = tab.pane(id) {
                PreviewPane(pane: pane, focused: id == tab.focusedPaneID && tab.hasSplits, actions: actions, panel: panel)
            }
        case .split(let axis, let ratio, let first, let second):
            GeometryReader { proxy in
                let gap: CGFloat = 4
                if axis == .horizontal {
                    let width = (proxy.size.width - gap) * ratio
                    HStack(spacing: gap) {
                        PreviewNode(node: first, tab: tab, actions: actions, panel: panel).frame(width: width)
                        PreviewNode(node: second, tab: tab, actions: actions, panel: panel)
                    }
                } else {
                    let height = (proxy.size.height - gap) * ratio
                    VStack(spacing: gap) {
                        PreviewNode(node: first, tab: tab, actions: actions, panel: panel).frame(height: height)
                        PreviewNode(node: second, tab: tab, actions: actions, panel: panel)
                    }
                }
            }
        }
    }
}

private struct PreviewPane: View {
    let pane: Pane
    let focused: Bool
    let actions: ChromeActions
    let panel: NSColor

    var body: some View {
        let activity = actions.activity(for: pane.id)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ProgramIcon(program: activity.program, size: 9)
                Text(PaneHeader.title(pane: pane, program: activity.program, folder: WorkspaceModel.Tab.abbreviate(pane.workingDirectory)))
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                ActivityIndicator(display: activity.display)
                    .scaleEffect(0.8)
            }
            .foregroundStyle(Color(nsColor: EditorStyle.colors.text).opacity(0.85))
            // The bottom of the screen, where the latest output is; lines cut at the edge, as a
            // terminal shows them, not wrapped.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.lastLines(of: actions.screenText(for: pane.id) ?? "").enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.system(size: 6.5, design: .monospaced))
            .foregroundStyle(Color(nsColor: EditorStyle.colors.text))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .clipped()
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Color(nsColor: panel)))
        .overlay(shape.strokeBorder(Color.primary.opacity(focused ? 0.35 : 0.12), lineWidth: 1))
        .clipShape(shape)
    }

    /// The screen's last lines with text (as many as a preview pane can hold).
    static func lastLines(of text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0.prefix(200)) }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return Array(lines.suffix(30))
    }
}
