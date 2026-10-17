import Foundation
import Observation
import PaneActivity
import WorkspaceModel

/// The agents of every tab, in every window, kept up to date for the sidebars' tab rows, with the
/// repositories they work in.
@MainActor
final class AgentDirectory {
    private let workspace: Workspace
    private let activity: ActivityTracker
    /// The agents of every tab, in every window, for the sidebars' tab rows.
    let list = AgentList()
    private var scheduled = false
    /// The folders the agents work in, as the list last found them.
    private var folders: Set<String> = []
    private var repositories = RepositoryCache()

    init(workspace: Workspace, activity: ActivityTracker) {
        self.workspace = workspace
        self.activity = activity
    }

    /// The list is worked out again on the next turn of the run loop: changes made together are
    /// one update.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Works the agents out, watching what that read (the windows, tabs and panes, the panes'
    /// folders, what runs in each), and publishes them when they changed.
    func refresh() {
        scheduled = false
        let tabs = withObservationTracking { summaries() } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.schedule() } }
        }
        list.update(tabs, liveTabs: Set(workspace.windows.flatMap { $0.tabs.map(\.id) }))
        lookUpRepositories()
    }

    /// Each tab's most urgent agent, and how many others it has.
    private func summaries() -> [TabID: TabAgentSummary] {
        var folders = Set<String>()
        var summaries: [TabID: TabAgentSummary] = [:]
        for window in workspace.windows {
            for tab in window.tabs {
                let entries = tab.orderedPanes.compactMap { pane -> AgentEntry? in
                    let status = activity.status(for: pane.id)
                    guard let program = status.activity.program, program.isAgent else { return nil }
                    // The agent's own folder: it may differ from the shell's (`cd x && claude`).
                    let folder = activity.agentDirectory(for: pane.id) ?? pane.workingDirectory
                    folders.insert(folder)
                    return AgentEntry(pane: pane.id, display: status.activity.display,
                                      repository: repositories.repository(for: folder) ?? Repository(root: folder, branch: nil),
                                      status: status)
                }
                guard let shown = AgentListing.mostUrgent(entries.map { ($0.pane, $0.display) }, focused: tab.focusedPaneID),
                      let entry = entries.first(where: { $0.pane == shown }) else { continue }
                summaries[tab.id] = TabAgentSummary(entry: entry, others: entries.count - 1)
            }
        }
        self.folders = folders
        return summaries
    }

    /// Looks up the repositories of the agents' folders off the main thread: new folders at once,
    /// the others again every few seconds (an agent may switch branches). Called after every
    /// activity tick too, while a window is on screen.
    func lookUpRepositories() {
        for folder in repositories.due(folders, at: Date()) {
            Task.detached(priority: .utility) { [weak self] in
                let repository = Repository.find(for: folder, in: DiskFiles())
                await self?.found(repository, for: folder)
            }
        }
    }

    private func found(_ repository: Repository, for folder: String) {
        if repositories.resolved(folder, repository, at: Date()) { schedule() }
    }
}
