import AppKit
import GhosttyBridge
import WorkspaceModel

/// Broadcast input (⌥⇧⌘I): what is typed in one pane of the tab goes to all of them. Keys typed
/// into a running program (an ssh session) reach the other panes running one; a command run from
/// the input bar runs in every pane.
extension TerminalWindowController {
    @objc func toggleBroadcast(_ sender: Any?) {
        guard let tab = state.selectedTab else { return }
        if chrome.broadcastTabs.contains(tab.id) {
            chrome.broadcastTabs.remove(tab.id)
        } else if tab.hasSplits {
            chrome.broadcastTabs.insert(tab.id)
        }
    }

    /// The other panes of `pane`'s tab while it broadcasts, those running a program (with no input
    /// bar): raw keys would be lost behind a bar.
    func broadcastPeers(of pane: PaneID) -> [TerminalSurfaceView] {
        guard let tab = state.tab(containing: pane), chrome.broadcastTabs.contains(tab.id) else { return [] }
        return tab.orderedPanes.compactMap { other in
            guard other.id != pane, shell(for: other.id)?.bar == .hidden else { return nil }
            return surfaces[other.id]
        }
    }

    func broadcastCommand(_ command: String, from pane: PaneID) {
        guard let tab = state.tab(containing: pane), chrome.broadcastTabs.contains(tab.id) else { return }
        for other in tab.orderedPanes where other.id != pane {
            shell(for: other.id)?.receiveBroadcast(command)
        }
    }

    /// A tab that lost its splits has nothing to broadcast to.
    func pruneBroadcast() {
        chrome.broadcastTabs = chrome.broadcastTabs.filter { id in state.tab(id: id)?.hasSplits == true }
    }
}
