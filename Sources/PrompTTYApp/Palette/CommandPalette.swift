import AppKit
import CommandEditing
import Observation
import SwiftUI

/// One thing the palette can do: go to a tab, run a menu command, open something.
struct PaletteEntry: Identifiable {
    let id: String
    let icon: String
    let title: String
    /// Beside the title, dimmed: a tab's folder, a command's menu.
    var subtitle: String?
    /// The shortcut that does the same, as the menu shows it.
    var shortcut: String?
    /// Other words it is found by.
    var keywords = ""
    let run: () -> Void
}

/// The command palette (⇧⌘P): every tab in every window, every menu command and a few more
/// things, fuzzy-filtered by typing. Built when it opens; nothing it lists changes while it is up.
@MainActor
@Observable
final class PaletteModel {
    var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    private(set) var results: [PaletteEntry] = []
    private(set) var selection: Int?
    @ObservationIgnored private let entries: [PaletteEntry]
    @ObservationIgnored private let ranking: [PaletteRanking.Entry]

    init(entries: [PaletteEntry]) {
        self.entries = entries
        ranking = entries.map { PaletteRanking.Entry(title: $0.title, keywords: [$0.subtitle ?? "", $0.keywords].joined(separator: " ")) }
        refresh()
    }

    var choice: PaletteEntry? { selection.flatMap { results.indices.contains($0) ? results[$0] : nil } }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max((selection ?? 0) + delta, 0), results.count - 1)
    }

    private func refresh() {
        results = PaletteRanking.rank(query, ranking).map { entries[$0] }
        selection = results.isEmpty ? nil : 0
    }
}

/// The palette itself, Raycast-style: a large search field over the list, on Liquid Glass.
struct CommandPaletteView: View {
    let model: PaletteModel
    let run: (PaletteEntry) -> Void
    let cancel: () -> Void

    static let width: CGFloat = 640
    static let rowHeight: CGFloat = 40
    private static let maxRows = 9
    private static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                PickerField(text: Binding(get: { model.query }, set: { model.query = $0 }),
                            placeholder: "Search tabs, commands and hosts…", onCommand: handle,
                            font: .systemFont(ofSize: 20))
                    .frame(height: 28)
            }
            .padding(.horizontal, 20)
            .frame(height: 60)

            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                            PaletteRow(entry: entry, selected: model.selection == index) { run(entry) }
                                .id(entry.id)
                        }
                        if model.results.isEmpty {
                            Text("No results")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: Self.rowHeight * 2)
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.never)
                .frame(height: CGFloat(max(2, min(model.results.count, Self.maxRows))) * (Self.rowHeight + 2) + 16)
                .onChange(of: model.choice?.id) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }

            Divider().opacity(0.5)

            HStack(spacing: 14) {
                Label("Command Palette", systemImage: "command")
                    .labelStyle(.titleAndIcon)
                Spacer()
                PaletteHint(keys: "↑↓", label: "Select")
                PaletteHint(keys: "↩", label: "Run")
                PaletteHint(keys: "esc", label: "Close")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 38)
        }
        .frame(width: Self.width)
        .glassEffect(.regular, in: Self.shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command Palette")
    }

    private func handle(_ command: PickerField.Command) -> Bool {
        switch command {
        case .up: model.moveSelection(by: -1)
        case .down: model.moveSelection(by: 1)
        case .left, .right: return false
        case .enter: if let choice = model.choice { run(choice) }
        case .escape: cancel()
        }
        return true
    }
}

/// One result: its symbol in a small tile, its name, where it comes from, and its shortcut as
/// keycaps.
private struct PaletteRow: View {
    let entry: PaletteEntry
    let selected: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: entry.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(entry.title)
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                if let shortcut = entry.shortcut {
                    Keycaps(shortcut: shortcut)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: CommandPaletteView.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            if selected {
                shape.fill(Color.primary.opacity(0.12))
            } else if hovering {
                shape.fill(Color.primary.opacity(0.05))
            }
        }
        .onHover { hovering = $0 }
        .accessibilityLabel(entry.title)
        .accessibilityHint(entry.subtitle ?? "Runs this command")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "⇧⌘D" as one keycap per key.
private struct Keycaps: View {
    let shortcut: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.keys(shortcut).enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .medium))
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel(shortcut)
    }

    /// Each modifier on its own cap, the key (which may be a word, "Space") on the last.
    static func keys(_ shortcut: String) -> [String] {
        let modifiers = Set("⌃⌥⇧⌘")
        var out: [String] = []
        var rest = Substring(shortcut)
        while let first = rest.first, modifiers.contains(first) {
            out.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }
}

private struct PaletteHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .frame(minHeight: 18)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
        }
    }
}

/// The palette over a window: a dimmed backdrop that closes it when clicked, the palette at the
/// top center.
struct CommandPaletteOverlay: View {
    let chrome: WindowChromeModel
    let actions: ChromeActions

    var body: some View {
        if let model = chrome.palette {
            ZStack(alignment: .top) {
                // Barely dimmed: the glass shows the terminal through it.
                Color.black.opacity(0.06)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.closePalette(running: nil) }
                    .accessibilityHidden(true)
                CommandPaletteView(model: model, run: { actions.closePalette(running: $0) },
                                   cancel: { actions.closePalette(running: nil) })
                    .padding(.top, 72)
                    .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
            }
            .transition(.opacity)
        }
    }
}

/// The menu bar's commands as palette entries.
@MainActor
enum MenuCommands {
    /// `window`: whose responders take the commands (the app may not be active, as when the
    /// palette is opened from the debug driver).
    /// `configured`: the shortcut PrompTTY has for a command by its title, as Settings shows it. A
    /// menu's own key equivalent is stored for the keyboard layout (⌃⌘= can read ⌃⌘` on one where
    /// = is shifted), so it is shown only for the menu's fixed items.
    static func entries(in menu: NSMenu?, window: NSWindow?, path: [String] = [],
                        configured: (String) -> String? = { _ in nil }) -> [PaletteEntry] {
        guard let menu else { return [] }
        var out: [PaletteEntry] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                // The palette lists tabs itself.
                guard item.title != "Go to Tab" else { continue }
                out += entries(in: submenu, window: window, path: path + [item.title], configured: configured)
                continue
            }
            guard let action = item.action, item.title != "Command Palette",
                  !Self.skipped.contains(action) else { continue }
            guard let target = item.target ?? responder(for: action, in: window) else { continue }
            if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) { continue }
            let title = item.title.hasSuffix("…") ? String(item.title.dropLast()) : item.title
            out.append(PaletteEntry(
                id: "menu:\(path.joined(separator: "/"))/\(item.title)",
                icon: Self.icon(forCommand: title) ?? Self.icon(for: path.first ?? ""),
                title: title,
                subtitle: path.joined(separator: " › ").nilIfEmpty,
                shortcut: configured(title) ?? shortcut(of: item),
                keywords: path.joined(separator: " "),
                run: { [weak target] in NSApp.sendAction(action, to: target, from: item) }
            ))
        }
        return out
    }

    /// The first in the window's responder chain, then its delegate, the app and its delegate,
    /// that takes `action`.
    private static func responder(for action: Selector, in window: NSWindow?) -> AnyObject? {
        var next: NSResponder? = window?.firstResponder
        while let responder = next {
            if responder.responds(to: action) { return responder }
            next = responder.nextResponder
        }
        for candidate in [window?.delegate as AnyObject?, window?.windowController, NSApp, NSApp.delegate as AnyObject?] {
            if let candidate, candidate.responds(to: action) { return candidate }
        }
        return nil
    }

    /// Window-list and standard items with nothing to offer here.
    private static let skipped: Set<Selector> = [
        #selector(NSWindow.makeKeyAndOrderFront(_:)),
        #selector(NSApplication.arrangeInFront(_:)),
        #selector(NSApplication.unhideAllApplications(_:)),
    ]

    /// A symbol of its own for the commands people run most.
    private static func icon(forCommand title: String) -> String? {
        let icons: [String: String] = [
            "New Window": "macwindow.badge.plus", "New Tab": "plus.square.on.square", "Pin Tab": "pin",
            "Unpin Tab": "pin.slash", "New Project": "folder.badge.plus", "Split Right": "rectangle.split.2x1",
            "Split Down": "rectangle.split.1x2", "Close Pane": "xmark.square", "Close Tab": "xmark.square",
            "Close Window": "xmark.rectangle", "Reopen Closed Tab": "arrow.uturn.backward.square",
            "Copy": "doc.on.doc", "Paste": "doc.on.clipboard", "Select All": "selection.pin.in.out",
            "Clear": "eraser", "Find": "magnifyingglass", "Find Next": "chevron.down", "Find Previous": "chevron.up",
            "Use Selection for Find": "text.magnifyingglass", "Copy Output": "doc.on.doc",
            "Copy Command": "chevron.forward.square", "Copy Command as Markdown": "text.badge.checkmark",
            "Rerun Command": "arrow.clockwise", "Bigger": "textformat.size.larger", "Smaller": "textformat.size.smaller",
            "Actual Size": "textformat.size", "Toggle Sidebar": "sidebar.left", "Toggle Tab Layout": "rectangle.topthird.inset.filled",
            "Quick Terminal": "rectangle.tophalf.inset.filled", "Enter Full Screen": "arrow.up.left.and.arrow.down.right",
            "Zoom Pane": "arrow.up.left.and.arrow.down.right", "Unzoom Pane": "arrow.down.right.and.arrow.up.left",
            "Equalize Panes": "square.grid.2x2", "Broadcast Input to All Panes": "dot.radiowaves.left.and.right",
            "Settings": "gearshape", "Secure Keyboard Entry": "lock", "Minimize": "minus.square",
            "Quit PrompTTY": "power", "About PrompTTY": "info.circle",
        ]
        if let icon = icons[title] { return icon }
        if title.hasPrefix("Focus Pane") { return "arrow.right.square" }
        if title.hasPrefix("Select") { return "text.line.first.and.arrowtriangle.forward" }
        return nil
    }

    private static func icon(for menu: String) -> String {
        switch menu {
        case "File": "doc"
        case "Edit": "pencil"
        case "View": "eye"
        case "Window": "macwindow"
        default: "gearshape"
        }
    }

    /// "⇧⌘D", as a menu shows an item's key equivalent.
    static func shortcut(of item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        let mask = item.keyEquivalentModifierMask
        var out = ""
        if mask.contains(.control) { out += "⌃" }
        if mask.contains(.option) { out += "⌥" }
        // An uppercase letter implies ⇧.
        if mask.contains(.shift) || (key != key.lowercased()) { out += "⇧" }
        if mask.contains(.command) { out += "⌘" }
        let names: [Character: String] = [
            "\r": "↩", "\u{1B}": "⎋", "\t": "⇥", " ": "Space", "\u{8}": "⌫", "\u{7F}": "⌫",
            Character(UnicodeScalar(NSUpArrowFunctionKey)!): "↑", Character(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
            Character(UnicodeScalar(NSLeftArrowFunctionKey)!): "←", Character(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
        ]
        if key.count == 1, let name = names[key.first!] { return out + name }
        return out + key.uppercased()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
