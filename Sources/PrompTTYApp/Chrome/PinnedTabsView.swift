import SwiftUI
import WorkspaceModel

/// Dia's pinned tabs: square tiles at the top of the sidebar, then a hairline above the other
/// tabs. While a tab is dragged with none pinned yet, an empty tile invites the drop.
struct PinnedTabsGrid: View {
    let state: WindowState
    let chrome: WindowChromeModel
    let actions: ChromeActions

    static let tileHeight: CGFloat = 40
    private static let spacing: CGFloat = 6
    static let maxColumns = 4

    @State private var dropTargeted = false
    /// The grid's right edge in the window, where the tiles' previews go.
    @State private var trailingEdge: CGFloat = 0

    var body: some View {
        let pinned = Array(state.tabs.prefix(state.pinnedCount))
        let dragging = chrome.draggingTab.map { id in !pinned.contains { $0.id == id } } ?? false
        if !pinned.isEmpty || dragging {
            VStack(spacing: 8) {
                // Up to four to a row, sharing its width, as Dia and Arc lay them out.
                let columns = min(max(pinned.count + (dragging ? 1 : 0), 1), Self.maxColumns)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns), spacing: Self.spacing) {
                    ForEach(Array(pinned.enumerated()), id: \.element.id) { index, tab in
                        TabRow(tab: tab, index: index, selected: tab.id == state.selectedTabID, style: .tile,
                               chrome: chrome, actions: actions, previewEdge: trailingEdge + ChromeMetrics.sidebarHorizontalPadding)
                            .frame(height: Self.tileHeight)
                    }
                    if dragging {
                        DropTile(targeted: dropTargeted)
                            .frame(height: Self.tileHeight)
                    }
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, 4)
            }
            .padding(.bottom, 6)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { trailingEdge = $0 }
            // Dropped between or past the tiles: pinned after the others.
            .onDrop(of: [DragPayload.tab], isTargeted: $dropTargeted) { providers in
                chrome.draggingTab = nil
                return DragPayload.loadID(DragPayload.tab, from: providers) { [actions] id in
                    actions.pinTab(TabID(rawValue: id), at: nil)
                }
            }
            .animation(.snappy(duration: 0.2), value: pinned.map(\.id))
            .animation(.snappy(duration: 0.2), value: dragging)
        }
    }
}

/// The empty tile a dragged tab can be dropped on to pin it.
private struct DropTile: View {
    let targeted: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.rowCornerRadius, style: .continuous)
        shape.fill(Color.accentColor.opacity(targeted ? 0.18 : 0.06))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(targeted ? 0.9 : 0.45), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
            .overlay {
                Image(systemName: "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel("Drop to pin")
    }
}
