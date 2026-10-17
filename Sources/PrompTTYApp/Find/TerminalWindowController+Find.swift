import AppKit
import GhosttyBridge
import WorkspaceModel

/// Find in the focused pane's scrollback, with the terminal's own search: ⌘F opens the pane's find
/// bar, ⌘G and ⇧⌘G go to the next and previous match, Esc closes it. The terminal highlights the
/// matches and reports how many there are; the bar (`FindBar`) shows that.
extension TerminalWindowController {
    @objc func find(_ sender: Any?) {
        guard let pane = state.selectedTab?.focusedPaneID else { return }
        let status = coordinator.activity.status(for: pane)
        if status.find == nil {
            status.setFind(PaneFind())
            surfaces[pane]?.performBindingAction("start_search")
        }
        status.updateFind { $0.focusRequest += 1 }
    }

    @objc func findNext(_ sender: Any?) { navigateFind(forward: true) }
    @objc func findPrevious(_ sender: Any?) { navigateFind(forward: false) }

    /// Looks for the selected text; the terminal answers with a search for it.
    @objc func useSelectionForFind(_ sender: Any?) {
        focusedSurface?.performBindingAction("search_selection")
    }

    private func navigateFind(forward: Bool) {
        guard let pane = state.selectedTab?.focusedPaneID else { return }
        // With the bar closed there is nothing to go to: open it.
        guard coordinator.activity.status(for: pane).find?.needle.isEmpty == false else { return find(nil) }
        findNavigate(in: pane, forward: forward)
    }

    // MARK: ChromeActions

    func findState(for pane: PaneID) -> PaneFind? { coordinator.activity.status(for: pane).find }

    func setFindText(_ text: String, in pane: PaneID) {
        let status = coordinator.activity.status(for: pane)
        guard status.find != nil, status.find?.needle != text else { return }
        status.updateFind {
            $0.needle = text
            if text.isEmpty {
                $0.total = nil
                $0.selected = nil
            }
        }
        surfaces[pane]?.performBindingAction("search:\(text)")
    }

    func findNavigate(in pane: PaneID, forward: Bool) {
        surfaces[pane]?.performBindingAction(forward ? "navigate_search:next" : "navigate_search:previous")
    }

    func closeFind(in pane: PaneID) {
        surfaces[pane]?.performBindingAction("end_search")
        coordinator.activity.status(for: pane).setFind(nil)
        focusSelectedPane()
    }
}
