import AppKit
import CommandEditing
import Observation
import SwiftUI

/// The bar's completion sources: what the shell reported, the file system, and git. One value
/// serves one completion list, so git's branches are read once per list, not per keystroke.
struct ShellCompletionSources: CompletionSources {
    let commands: Set<String>
    let exports: Set<String>
    let git: String
    private let branches = BranchCache()

    func commandNames() -> Set<String> { commands }
    func exportNames() -> Set<String> { exports }

    func entries(inDirectory path: String) -> [(name: String, isDirectory: Bool)] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.map { item in
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return (name: item.lastPathComponent, isDirectory: isDirectory == true)
        }
    }

    func gitBranches(in directory: String) -> [String] {
        branches.value(for: directory) {
            let out = PaneShell.run(git, ["-C", directory, "for-each-ref", "--format=%(refname:short)", "refs/heads"], timeout: 1) ?? ""
            return out.split(separator: "\n").map(String.init)
        }
    }
}

private final class BranchCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: [String]] = [:]

    func value(for directory: String, load: () -> [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[directory] { return cached }
        let loaded = load()
        cache[directory] = loaded
        return loaded
    }
}

@MainActor
@Observable
final class CompletionList {
    var items: [String] = []
    var selected = 0
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

    func show(_ items: [String], anchor: NSRect, in window: NSWindow, font: NSFont) {
        list.items = items
        list.selected = 0
        let panel = self.panel ?? makePanel(font: font)
        self.panel = panel
        let rows = min(items.count, Self.maxRows)
        let width = min(520, max(220, items.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 36)
        let height = CGFloat(rows) * Self.rowHeight + 10
        // Above the caret: the bar sits at the bottom of the pane.
        let origin = NSPoint(x: anchor.minX - 8, y: anchor.maxY + 4)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func update(_ items: [String]) {
        let keep = selectedItem
        list.items = items
        list.selected = keep.flatMap { items.firstIndex(of: $0) } ?? 0
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
                    ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                        Text(item)
                            .font(font)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                            .padding(.horizontal, 8)
                            .background {
                                if index == list.selected {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor.opacity(0.85))
                                }
                            }
                            .foregroundStyle(index == list.selected ? Color.white : Color.primary)
                            .id(index)
                    }
                }
                .padding(5)
            }
            .scrollIndicators(.never)
            .onChange(of: list.selected) { _, new in proxy.scrollTo(new) }
        }
        .background(FlatSurface(cornerRadius: 9))
    }
}
