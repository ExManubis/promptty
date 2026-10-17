import Foundation
import Preferences
import WorkspaceModel

/// What the session file names for each pane's scrollback: the archive files it writes, and the
/// marks that tell which panes changed since.
@MainActor
final class SessionPersistence {
    private let workspace: Workspace
    private let preferences: PreferencesController
    /// A window's controller, for its panes' terminals.
    private let controller: (WindowID) -> TerminalWindowController?

    init(workspace: Workspace, preferences: PreferencesController, controller: @escaping (WindowID) -> TerminalWindowController?) {
        self.workspace = workspace
        self.preferences = preferences
        self.controller = controller
    }

    /// Writes what each pane shows to the scrollback archive (at quit, and every two minutes so a
    /// crash loses little), and returns the file kept for each pane. Only the last lines are read.
    /// Except at quit, a pane whose screen has not changed since it was last written keeps that
    /// file, and the files are written off the main thread. A restored pane never shown keeps the
    /// file it came with. Nothing (and no files) when the setting is off.
    func archiveScrollback(quitting: Bool) -> [PaneID: String] {
        let archive = ScrollbackArchive(directory: AppPaths.scrollback)
        let settings = preferences.settings
        let write = { (work: @escaping @Sendable () -> Void) in
            if quitting { Self.archiveQueue.sync(execute: work) } else { Self.archiveQueue.async(execute: work) }
        }
        guard settings.restoreSession, settings.restoreScrollback else {
            write { archive.clear() }
            lastArchive = [:]
            archiveMarks = [:]
            return [:]
        }
        let now = Date()
        var texts: [String: String] = [:]
        var kept = Set<String>()
        var names: [PaneID: String] = [:]
        var marks: [PaneID: ArchiveMark] = [:]
        for state in workspace.windows {
            guard let controller = controller(state.id) else { continue }
            for pane in state.tabs.flatMap(\.orderedPanes) {
                if let surface = controller.surfaces[pane.id] {
                    let mark = ArchiveMark(rows: surface.totalRows, screen: surface.activeScreenText()?.hashValue)
                    marks[pane.id] = mark
                    if !quitting, archiveMarks[pane.id] == mark {
                        if let name = lastArchive[pane.id] {
                            kept.insert(name)
                            names[pane.id] = name
                        }
                        continue
                    }
                    guard let text = surface.recentText(rows: ScrollbackArchive.maxLines, styled: true),
                          let archived = ScrollbackArchive.archived(text, savedAt: now) else { continue }
                    let name = Self.fileName(for: pane.id)
                    texts[name] = archived
                    names[pane.id] = name
                } else if let pending = pane.restoredScrollback {
                    kept.insert(pending)
                    names[pane.id] = pending
                }
            }
        }
        write { [texts, kept] in archive.replace(with: texts, keeping: kept) }
        lastArchive = names
        archiveMarks = marks
        return names
    }

    /// The archive file a pane's scrollback is written to.
    private static func fileName(for pane: PaneID) -> String { "\(pane.rawValue.uuidString).vt" }

    /// Archive files are written here, in order; at quit the app waits for it.
    private static let archiveQueue = DispatchQueue(label: "dev.promptty.scrollback", qos: .utility)

    /// What a pane's terminal held when it was last archived: its rows, and its screen's text.
    private struct ArchiveMark: Equatable {
        let rows: Int?
        let screen: Int?
    }

    private var archiveMarks: [PaneID: ArchiveMark] = [:]

    private var lastArchive: [PaneID: String] = [:]

    /// The archive files written last, for a session saved in between: each pane's, or the one a
    /// restored pane came with (until its shell prints it).
    var archivedScrollback: [PaneID: String] {
        guard preferences.settings.restoreSession, preferences.settings.restoreScrollback else { return [:] }
        var names: [PaneID: String] = [:]
        for pane in workspace.windows.flatMap(\.tabs).flatMap(\.orderedPanes) {
            if let name = lastArchive[pane.id] ?? pane.restoredScrollback { names[pane.id] = name }
        }
        return names
    }
}
