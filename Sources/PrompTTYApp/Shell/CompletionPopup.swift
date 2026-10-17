import AppKit
import CommandEditing
import Observation
import SwiftUI

/// The file system side of completion: read off the main thread, once per completion list.
enum DirectoryListing {
    nonisolated static func entries(inDirectory path: String) -> [(name: String, isDirectory: Bool)] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.map { item in
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return (name: item.lastPathComponent, isDirectory: isDirectory == true)
        }
    }
}

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
        let panel = self.panel ?? makePanel(font: font)
        self.panel = panel
        panel.appearance = window.effectiveAppearance
        list.dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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

    private func makePanel(font: NSFont) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: CompletionListView(list: list, font: Font(font), rowHeight: Self.rowHeight))
        return panel
    }
}

private struct CompletionListView: View {
    let list: CompletionList
    let font: Font
    let rowHeight: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    let rows = Array(list.items.enumerated())
                    ForEach(list.bottomUp ? rows.reversed() : rows, id: \.offset) { index, item in
                        row(item, selected: index == list.selected)
                            .id(index)
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(list.bottomUp ? .bottom : .top)
            .onChange(of: list.selected) { _, new in proxy.scrollTo(new) }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, list.dark ? .dark : .light)
    }

    /// A candidate as Rex's path picker shows it: its kind's icon and its own name, the selected
    /// one on the accent color.
    private func row(_ item: String, selected: Bool) -> some View {
        let folder = item.hasSuffix("/")
        let path = item.contains("/")
        return HStack(spacing: 7) {
            if path {
                Image(systemName: folder ? "folder.fill" : "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? list.onAccent : (folder ? list.accent : Color.secondary))
                    .frame(width: 14)
            }
            Text(Self.name(of: item))
                .font(font)
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

    /// A path's last name ("config/aerc/" shows "aerc"); anything else as it is.
    static func name(of item: String) -> String {
        let trimmed = item.hasSuffix("/") ? String(item.dropLast()) : item
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}
