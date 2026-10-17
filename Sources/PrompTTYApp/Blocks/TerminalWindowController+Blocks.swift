import AppKit
import GhosttyBridge
import Preferences

/// Command blocks in the focused pane: ⌘↑ and ⌘↓ select the previous and next command (⌃⌘↑ and
/// ⌃⌘↓ the failed ones), Rerun puts it in the input bar, the copy commands copy the selected one
/// (else the newest), and while one is selected ⌘C copies its output and Esc lets it go.
extension TerminalWindowController {
    var focusedBlocks: BlockOverlayView? {
        state.selectedTab.flatMap { blocks(for: $0.focusedPaneID) }
    }

    @objc func selectPreviousCommand(_ sender: Any?) { focusedBlocks?.selectPrevious() }
    @objc func selectNextCommand(_ sender: Any?) { focusedBlocks?.selectNext() }
    @objc func copyCommandOutput(_ sender: Any?) { focusedBlocks?.copy(.output) }
    @objc func copyCommandLine(_ sender: Any?) { focusedBlocks?.copy(.command) }
    @objc func copyCommandMarkdown(_ sender: Any?) { focusedBlocks?.copy(.markdown) }
    @objc func selectPreviousFailedCommand(_ sender: Any?) { focusedBlocks?.selectPreviousFailed() }
    @objc func selectNextFailedCommand(_ sender: Any?) { focusedBlocks?.selectNextFailed() }
    @objc func rerunCommand(_ sender: Any?) { focusedBlocks?.rerun() }

    /// ⌘C (the Copy shortcut) and Esc while a block is selected, before the bar or the terminal
    /// sees them. Text selected in either is copied as usual.
    func handleBlockKeys(_ event: NSEvent) -> Bool {
        guard let blocks = focusedBlocks, blocks.selection != nil, window?.attachedSheet == nil,
              let responder = window?.firstResponder,
              responder is TerminalSurfaceView || responder is CommandTextView,
              (responder as? NSTextInputClient)?.hasMarkedText() != true,
              let shortcut = ShortcutRecorder.shortcut(from: event) else { return false }
        if shortcut == Shortcut(key: "escape", modifiers: []) {
            blocks.clearSelection()
            return true
        }
        if shortcut == coordinator.preferences.shortcuts.shortcut(for: .copy), !hasSelectedText(responder) {
            blocks.copy(.output)
            return true
        }
        return false
    }

    /// A click anywhere but on a block's own header or buttons lets the selection go.
    func mouseDownInWindow(_ event: NSEvent) {
        guard let blocks = focusedBlocks, blocks.selection != nil,
              let hit = window?.contentView?.hitTest(event.locationInWindow),
              !hit.isDescendant(of: blocks) else { return }
        blocks.clearSelection()
    }

    private func hasSelectedText(_ responder: NSResponder) -> Bool {
        if let text = responder as? NSTextView { return text.selectedRange().length > 0 }
        if let surface = responder as? TerminalSurfaceView { return surface.hasSelection }
        return false
    }
}
