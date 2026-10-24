import PaneActivity
import PrompTTYChrome
import SwiftUI
import WorkspaceModel

/// The ring of one pane's box, observed on its own: only the ring redraws as the report changes.
struct StatusProgressRing: View {
    let status: PaneStatus

    var body: some View {
        if let progress = status.progress, ProgressRing.shows(progress) { ProgressRing(progress: progress) }
    }
}

/// The ring of a tab: the report of its first pane that has one to show (the focused pane first).
struct TabProgressRing: View {
    let panes: [PaneID]
    let actions: ChromeActions

    var body: some View {
        if let progress = panes.lazy.compactMap({ actions.progress(for: $0) }).first(where: ProgressRing.shows) {
            ProgressRing(progress: progress)
        }
    }
}
