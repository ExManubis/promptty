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

struct CommandPaletteView: View {
    let model: PaletteModel
    let run: (PaletteEntry) -> Void
    let cancel: () -> Void

    var body: some View {
        PickerPanel(
            icon: "command",
            title: "Command Palette",
            placeholder: "Search tabs and commands",
            query: Binding(get: { model.query }, set: { model.query = $0 }),
            note: model.results.isEmpty ? "Nothing matches" : nil,
            rowCount: model.results.count,
            selectedID: model.choice.map { AnyHashable($0.id) },
            hints: [("↑↓", "select"), ("⏎", "run"), ("esc", "close")],
            onCommand: handle,
            width: 520
        ) {
            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                let selected = model.selection == index
                PickerRow(icon: entry.icon, title: entry.title, selected: selected,
                          accessibilityHint: entry.subtitle ?? "Runs this command", open: { run(entry) }) { _ in
                    HStack(spacing: 8) {
                        if let subtitle = entry.subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.head)
                                .opacity(0.8)
                        }
                        if let shortcut = entry.shortcut {
                            Text(shortcut)
                                .font(.system(size: 11, weight: .medium).monospaced())
                        }
                    }
                    .padding(.trailing, 6)
                }
                .id(entry.id)
            }
        }
        .background(FlatSurface(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

/// The palette over a window: a dimmed backdrop that closes it when clicked, the palette at the
/// top center.
struct CommandPaletteOverlay: View {
    let chrome: WindowChromeModel
    let actions: ChromeActions

    var body: some View {
        if let model = chrome.palette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.closePalette(running: nil) }
                    .accessibilityHidden(true)
                CommandPaletteView(model: model, run: { actions.closePalette(running: $0) },
                                   cancel: { actions.closePalette(running: nil) })
                    .padding(.top, 72)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
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
    static func entries(in menu: NSMenu?, window: NSWindow?, path: [String] = []) -> [PaletteEntry] {
        guard let menu else { return [] }
        var out: [PaletteEntry] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                // The palette lists tabs itself.
                guard item.title != "Go to Tab" else { continue }
                out += entries(in: submenu, window: window, path: path + [item.title])
                continue
            }
            guard let action = item.action, item.title != "Command Palette",
                  !Self.skipped.contains(action) else { continue }
            guard let target = item.target ?? responder(for: action, in: window) else { continue }
            if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) { continue }
            let title = item.title.hasSuffix("…") ? String(item.title.dropLast()) : item.title
            out.append(PaletteEntry(
                id: "menu:\(path.joined(separator: "/"))/\(item.title)",
                icon: Self.icon(for: path.first ?? ""),
                title: title,
                subtitle: path.joined(separator: " › ").nilIfEmpty,
                shortcut: shortcut(of: item),
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
