import PaneActivity
import SwiftUI
import WorkspaceModel

/// A tab in miniature, shown beside the sidebar while the pointer rests on its row: its split
/// layout, each pane's last lines in the terminal's colors, its program and activity. Text, not
/// pixels: a hidden tab is not drawn, and stays live this way.
struct TabPreview: View {
    let tab: WorkspaceModel.Tab
    let actions: ChromeActions
    /// The window's chrome, for the terminal's colors as they are now.
    let chrome: WindowChromeModel
    /// A pinned tile's preview names the tab, which the tile does not.
    var titled = false

    static let size = CGSize(width: 380, height: 236)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if titled {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(tab.listTitle)
                        .font(.system(size: 12, weight: .semibold))
                    if let subtitle = tab.listSubtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }
            // The tick reaches every pane, so their text is read again each second.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                PreviewNode(node: tab.root, tab: tab, actions: actions, panel: chrome.panelColor, tick: context.date)
            }
            .environment(\.colorScheme, chrome.panelIsDark ? .dark : .light)
            .frame(width: Self.size.width, height: Self.size.height)
        }
        .padding(7)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of \(tab.listTitle)")
    }
}

private struct PreviewNode: View {
    let node: SplitNode
    let tab: WorkspaceModel.Tab
    let actions: ChromeActions
    let panel: NSColor
    let tick: Date

    var body: some View {
        switch node {
        case .leaf(let id):
            if let pane = tab.pane(id) {
                PreviewPane(pane: pane, focused: id == tab.focusedPaneID && tab.hasSplits, actions: actions, panel: panel, tick: tick)
            }
        case .split(let axis, let ratio, let first, let second):
            GeometryReader { proxy in
                let gap: CGFloat = 4
                if axis == .horizontal {
                    let width = (proxy.size.width - gap) * ratio
                    HStack(spacing: gap) {
                        PreviewNode(node: first, tab: tab, actions: actions, panel: panel, tick: tick).frame(width: width)
                        PreviewNode(node: second, tab: tab, actions: actions, panel: panel, tick: tick)
                    }
                } else {
                    let height = (proxy.size.height - gap) * ratio
                    VStack(spacing: gap) {
                        PreviewNode(node: first, tab: tab, actions: actions, panel: panel, tick: tick).frame(height: height)
                        PreviewNode(node: second, tab: tab, actions: actions, panel: panel, tick: tick)
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
    /// Changes every second: the screen is read again.
    let tick: Date

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
            // Over a clear area that takes the space there is: the lines start at its bottom and
            // what does not fit is cut off at the top.
            Color.clear
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(Self.lastLines(of: actions.screenText(for: pane.id) ?? "").enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: 6.5, design: .monospaced))
                    .foregroundStyle(Color(nsColor: EditorStyle.colors.text))
                }
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
