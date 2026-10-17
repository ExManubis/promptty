import AppKit
import CommandEditing
import Observation
import SwiftUI

@MainActor
@Observable
final class CompletionList {
    var items: [String] = []
    var selected = 0
    /// Best match at the bottom, next to the caret, as Rex's path picker lists them.
    var bottomUp = false
    /// The theme's accent (`EditorColors.accent`), and the text that reads on it.
    var accent: Color = .accentColor
    var onAccent: Color = .white
    /// Light or dark as the pane's window is (its theme's), not as the system is.
    var dark = true
    /// The theme's background, for the smoked glass.
    var tint: NSColor = .black
    /// The bar's font when the list was shown: it changes with the terminal's in Settings.
    var font: Font = .body
}

/// The list of completions above the caret, in a borderless child window of the pane's window.
/// It never takes focus: the bar keeps the keys and drives it.
@MainActor
final class CompletionPopup {
    private let list = CompletionList()
    private var panel: NSPanel?
    private static let rowHeight: CGFloat = 22
    private static let maxRows = 10

    var isVisible: Bool { panel?.isVisible == true }
    var selectedItem: String? { list.items.indices.contains(list.selected) ? list.items[list.selected] : nil }

    var bottomUp: Bool { list.bottomUp }

    func show(_ items: [String], anchor: NSRect, in window: NSWindow, font: NSFont, bottomUp: Bool = false) {
        list.items = items
        list.selected = 0
        list.bottomUp = bottomUp
        let accent = EditorStyle.colors.accent
        list.accent = Color(nsColor: accent)
        list.onAccent = ChromeTint.isDark(accent) ? .white : .black
        list.font = Font(font)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.appearance = window.effectiveAppearance
        list.dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let chrome = (window.windowController as? TerminalWindowController)?.chrome {
            list.dark = chrome.panelIsDark
            list.tint = chrome.panelColor
        }
        let rows = min(items.count, Self.maxRows)
        let width = min(520, max(220, items.map { (CompletionListView.name(of: $0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 56)
        let height = CGFloat(rows) * Self.rowHeight + 10
        // Above the caret: the bar sits at the bottom of the pane.
        let origin = NSPoint(x: anchor.minX - 8, y: anchor.maxY + 4)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    /// New items; the panel keeps its place and grows or shrinks from the caret's side.
    func update(_ items: [String]) {
        let keep = selectedItem
        list.items = items
        list.selected = keep.flatMap { items.firstIndex(of: $0) } ?? 0
        guard let panel else { return }
        var frame = panel.frame
        frame.size.height = CGFloat(min(items.count, Self.maxRows)) * Self.rowHeight + 10
        panel.setFrame(frame, display: true)
    }

    func move(by delta: Int) {
        guard !list.items.isEmpty else { return }
        list.selected = (list.selected + delta + list.items.count) % list.items.count
    }

    var onClose: (() -> Void)?

    func close() {
        onClose?()
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: CompletionListView(list: list, rowHeight: Self.rowHeight))
        return panel
    }
}

private struct CompletionListView: View {
    let list: CompletionList
    let rowHeight: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Lazy, and the selection read only by the rows (and the scroller below): ↑/↓
                // redraws the rows on screen, not all of up to 500.
                LazyVStack(spacing: 0) {
                    let rows = Array(list.items.enumerated())
                    ForEach(list.bottomUp ? rows.reversed() : rows, id: \.element) { index, item in
                        CompletionRow(list: list, item: item, index: index, rowHeight: rowHeight)
                            .id(item)
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(list.bottomUp ? .bottom : .top)
            .background(SelectionScroller(list: list, proxy: proxy))
        }
        // Smoked glass, as the panes and the tab bar.
        .modifier(SmokedGlass(shape: RoundedRectangle(cornerRadius: 12, style: .continuous), tint: list.tint, dark: list.dark))
        .environment(\.colorScheme, list.dark ? .dark : .light)
    }

    /// A path's last name ("config/aerc/" shows "aerc"); anything else as it is.
    static func name(of item: String) -> String {
        let trimmed = item.hasSuffix("/") ? String(item.dropLast()) : item
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}

/// Keeps the selected row in view; on its own so the list itself does not observe the selection.
private struct SelectionScroller: View {
    let list: CompletionList
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear.onChange(of: list.selected) { _, new in
            if list.items.indices.contains(new) { proxy.scrollTo(list.items[new]) }
        }
    }
}

/// A candidate as Rex's path picker shows it: its kind's icon and its own name, the selected one on
/// the accent color.
private struct CompletionRow: View {
    let list: CompletionList
    let item: String
    let index: Int
    let rowHeight: CGFloat

    var body: some View {
        let selected = index == list.selected
        let folder = item.hasSuffix("/")
        let path = item.contains("/")
        HStack(spacing: 7) {
            if path {
                Image(systemName: folder ? "folder.fill" : "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? list.onAccent : (folder ? list.accent : Color.secondary))
                    .frame(width: 14)
            }
            Text(CompletionListView.name(of: item))
                .font(list.font)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .padding(.horizontal, 8)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(list.accent)
            }
        }
        .foregroundStyle(selected ? list.onAccent : Color.primary)
    }
}
