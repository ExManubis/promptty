import AppKit
import GhosttyBridge
import PaneActivity
import UniformTypeIdentifiers
import WorkspaceModel

/// What libghostty asks of the app: carried out on the pane, tab or window it came from.
extension WorkspaceCoordinator {
    // MARK: GhosttyActionSink

    func handle(_ action: GhosttyAction, target: GhosttyActionTarget) -> Bool {
        // The quick terminal is no pane: it closes itself and copes with nothing else.
        if case .surface(let view) = target, view.token?.base is QuickTerminal.Token {
            switch action {
            case .closeSurface, .showChildExited:
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.quickTerminal?.surfaceClosed() } }
                return true
            case .scrollbar, .cellSize, .render, .mouseOverLink, .initialSize:
                return true
            default:
                return false
            }
        }
        // Constant streams, and one pane's own box and find bar: no `locate` for them.
        if let handled = GhosttyFastPath(activity: activity).handle(action, target: target) { return handled }
        let located: (WindowState, Tab, Pane, TerminalWindowController)?
        if case .surface(let view) = target { located = locate(view) } else { located = nil }
        let state = located?.0 ?? keyWindowState

        switch action {
        case .newWindow:
            newWindow(workingDirectory: located?.2.workingDirectory)
            return true
        case .newTab:
            guard let state else { return false }
            newTab(in: state)
            return true
        case .closeTab(let mode):
            guard let state else { return false }
            let selected = located?.1.id ?? state.selectedTabID
            guard let selected else { return false }
            switch mode {
            case .this: closeTab(selected)
            case .others: state.tabs.map(\.id).filter { $0 != selected }.forEach(closeTab)
            case .right:
                guard let i = state.index(of: selected) else { return false }
                state.tabs.dropFirst(i + 1).map(\.id).forEach(closeTab)
            }
            return true
        case .closeWindow:
            guard let state else { return false }
            controller(for: state.id)?.window?.performClose(nil)
            return true
        case .quit:
            NSApp.terminate(nil)
            return true
        case .gotoTab(let g):
            guard let state else { return false }
            let target: GotoTabTarget
            switch g {
            case .index(let n): target = .index(n)
            case .previous: target = .previous
            case .next: target = .next
            case .last: target = .last
            }
            let moved = state.gotoTab(target)
            if moved { controller(for: state.id)?.reload(); modelDidChange() }
            return moved
        case .moveTab(let amount):
            guard let state else { return false }
            let moved = state.moveSelectedTab(by: amount)
            if moved { controller(for: state.id)?.reload(); modelDidChange() }
            return moved
        case .setTitle(let title), .setTabTitle(let title):
            guard let located else { return false }
            // Agents animate a spinner in their title many times a second. Every change redraws
            // the tab row, the Agents entry and the window title, and each redraw blocks the main
            // thread on the window server, which also presents the terminal's frames: a working
            // agent made typing and its own animation stutter. Without the spinner the title
            // rarely changes, and an unchanged title changes nothing.
            let shown = Pane.terminalTitle(title)
            guard located.2.title != shown else { return true }
            located.2.title = shown
            located.3.reload()
            return true
        case .pwd(let dir):
            guard let located else { return false }
            // The integration's ready signal is a report under a reserved path, not a directory.
            if located.3.shell(for: located.2.id)?.directoryReported(dir) == true { return true }
            located.2.workingDirectory = dir
            located.3.reload()
            modelDidChange()
            return true
        case .initialSize(let w, let h):
            guard let located else { return false }
            located.3.applyInitialTerminalSize(CGSize(width: Double(w), height: Double(h)))
            return true
        case .scrollbar, .cellSize:
            return true // handled by the fast path, before the pane lookup
        case .render, .configChange:
            return true
        case .colorChange(let kind, let r, let g, let b):
            // Only the focused pane of the selected tab (OSC 11) tints its own window.
            guard kind == .background, let located, located.0.selectedTabID == located.1.id,
                  located.1.focusedPaneID == located.2.id else { return false }
            let color = NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            located.3.setColors(frame: ChromeTint.frame(forTerminalBackground: color, strength: preferences.settings.tintStrength), panel: color)
            return true
        case .showChildExited(let code, _):
            guard let located else { return false }
            located.3.chrome.exitedPanes[located.2.id] = code
            return true
        case .closeSurface(let processAlive):
            guard let located else { return false }
            let paneID = located.2.id
            if processAlive, preferences.settings.confirmCloseRunning {
                let message = located.1.hasSplits ? "Close this pane?" : "Close this tab?"
                located.3.confirmClose(message: message, informativeText: "A process is still running in it.") { [weak self] in
                    self?.closePane(paneID)
                }
            } else {
                closePane(paneID)
            }
            return true
        case .desktopNotification(let title, let body):
            // A program (an agent waiting for the user) asks for attention: marked and notified
            // where the user is not looking; where they are, they see it already.
            guard let located else {
                Notifications.post(title: title.isEmpty ? "PrompTTY" : title, body: body, pane: nil)
                return true
            }
            activity.attention(located.2.id, message: [title, body].filter { !$0.isEmpty }.joined(separator: ": "))
            return true
        case .ringBell:
            if let located, activity.attention(located.2.id, message: nil) { return true }
            NSSound.beep()
            return true
        case .commandFinished(let code, let duration):
            guard let located else { return false }
            activity.exitReported(located.2.id, code: Int(code))
            activity.clearProgress(located.2.id)
            located.3.shell(for: located.2.id)?.commandFinished(code: code, durationNs: duration)
            remoteCommandFinished(located.2.id)
            located.3.blocks(for: located.2.id)?.setNeedsRefresh()
            return true
        case .secureInput(let request):
            guard let located else { return false }
            let pane = located.2.id
            switch request {
            case .on: secureInput.setRequested(pane, true)
            case .off: secureInput.setRequested(pane, false)
            case .toggle: secureInput.setRequested(pane, !secureInput.isRequested(pane))
            }
            refreshSecureIndicators()
            return true
        case .openURL(let kind, let text):
            // Always true, even when refused: false would make libghostty `open` the text itself,
            // past every refusal of `LinkTarget`.
            let decision = LinkTarget.decide(text, kind: kind, relativeTo: located?.2.workingDirectory)
            // Carried out on the next turn of the run loop, never inside this callback: a ⌘-click
            // reaches here with libghostty holding the terminal's lock, and the confirmation's
            // modal alert (or another app coming forward) takes the keys from the window, whose
            // focus change calls back into libghostty for that same lock on this thread.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.openLink(decision) }
            }
            return true
        case .reloadConfig, .openConfig, .mouseShape, .mouseVisibility, .mouseOverLink, .progressReport, .programStatus, .unhandled,
             .startSearch, .endSearch, .searchTotal, .searchSelected:
            // Config, mouse-shape and mouse-visibility actions are handled by the runtime.
            return false
        }
    }

    // MARK: Lookup

    private func locate(_ view: TerminalSurfaceView) -> (WindowState, Tab, Pane, TerminalWindowController)? {
        guard let id = view.token?.base as? PaneID,
              let (state, tab) = workspace.tab(containing: id),
              let pane = tab.pane(id),
              let controller = self.controller(for: state.id) else { return nil }
        return (state, tab, pane, controller)
    }

    private var keyWindowState: WindowState? {
        allControllers.first { $0.window?.isKeyWindow == true }?.state ?? workspace.windows.first
    }

    // MARK: Links

    /// Carries out what `LinkTarget` decided; a refusal or a failure beeps. Nothing is ever run.
    private func openLink(_ decision: LinkDecision) {
        switch decision {
        case .open(let url):
            if !NSWorkspace.shared.open(url) { NSSound.beep() }
        case .openAsText(let url):
            guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { NSSound.beep() }
            }
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .confirm(let url):
            let alert = NSAlert()
            alert.messageText = "Open this link?"
            alert.informativeText = url.absoluteString
            // The first button is the default one.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Open")
            if alert.runModal() == .alertSecondButtonReturn, !NSWorkspace.shared.open(url) { NSSound.beep() }
        case .refuse:
            NSSound.beep()
        }
    }
}

/// The actions libghostty sends constantly (the scrollback moving, the mouse over a link) or about
/// one pane's own progress and find bar: answered from the surface itself, without looking its pane
/// up in the model.
@MainActor
struct GhosttyFastPath {
    let activity: ActivityTracker

    /// Whether `action` was handled; nil when it is none of these, for the pane lookup to handle.
    func handle(_ action: GhosttyAction, target: GhosttyActionTarget) -> Bool? {
        switch action {
        // The screen moved in the scrollback, the scrollback grew, or rows changed height: the
        // command blocks moved.
        case .scrollbar(let total, _, _):
            if case .surface(let view) = target {
                view.onLayoutChange?()
                if let pane = view.token?.base as? PaneID { activity.rowsReported(pane, total: total) }
            }
            return true
        case .cellSize:
            if case .surface(let view) = target { view.onLayoutChange?() }
            return true
        case .mouseOverLink(let link):
            // On every mouse move over text, so straight to the pane's card.
            if case .surface(let view) = target { view.onLinkHover?(link) }
            return true
        case .progressReport, .programStatus, .startSearch, .endSearch, .searchTotal, .searchSelected:
            guard case .surface(let view) = target, let pane = view.token?.base as? PaneID else { return false }
            handle(action, from: view, in: pane)
            return true
        default:
            return nil
        }
    }

    /// An action about one pane's box or find bar.
    private func handle(_ action: GhosttyAction, from view: TerminalSurfaceView, in pane: PaneID) {
        switch action {
        case .progressReport(let state, let percent):
            // Often while a program runs, so straight to the pane's box.
            let kind: PaneProgress.Kind?
            switch state {
            case .remove: kind = nil
            case .set: kind = .set
            case .error: kind = .error
            case .indeterminate: kind = .indeterminate
            case .pause: kind = .pause
            }
            activity.reportProgress(pane, kind: kind, percent: percent)
        case .programStatus(let report):
            activity.programStatus(pane, report)
        case .startSearch(let needle):
            let status = activity.status(for: pane)
            if status.find == nil { status.setFind(PaneFind()) }
            status.updateFind { $0.focusRequest += 1 }
            // Use Selection for Find: the terminal names the text but leaves looking for it to us.
            if !needle.isEmpty {
                status.updateFind { $0.needle = needle }
                view.performBindingAction("search:\(needle)")
            }
        case .endSearch:
            activity.status(for: pane).setFind(nil)
        case .searchTotal(let total):
            activity.status(for: pane).updateFind { $0.total = total }
        case .searchSelected(let selected):
            activity.status(for: pane).updateFind { $0.selected = selected }
        default:
            break
        }
    }
}
