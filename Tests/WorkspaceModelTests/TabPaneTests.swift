import XCTest
@testable import WorkspaceModel

@MainActor
final class TabPaneTests: XCTestCase {
    func testNewTabHasOneFocusedPaneCarryingTitleAndDirectory() {
        let tab = Tab(title: "zsh", workingDirectory: "/tmp")
        XCTAssertEqual(tab.root.leaves, [tab.focusedPaneID])
        XCTAssertEqual(tab.focusedPane.title, "zsh")
        XCTAssertEqual(tab.workingDirectory, "/tmp")
        XCTAssertFalse(tab.hasSplits)
    }

    func testSplitFocusesNewPaneAndTitleFollowsFocus() {
        let tab = Tab(title: "first", workingDirectory: "/a")
        let original = tab.focusedPaneID
        let pane = tab.split(original, direction: .right, workingDirectory: "/b")
        pane.title = "second"
        XCTAssertEqual(tab.focusedPaneID, pane.id)
        XCTAssertEqual(tab.title, "second")
        XCTAssertEqual(tab.workingDirectory, "/b")
        XCTAssertTrue(tab.hasSplits)
        tab.focus(original)
        XCTAssertEqual(tab.title, "first")
        XCTAssertEqual(tab.workingDirectory, "/a")
    }

    func testCustomTitleStillWinsOverFocusedPane() {
        let tab = Tab(title: "first", customTitle: "Mine", workingDirectory: "/a")
        _ = tab.split(tab.focusedPaneID, direction: .down, workingDirectory: "/b")
        XCTAssertEqual(tab.displayTitle, "Mine")
    }

    func testFocusIgnoresUnknownPane() {
        let tab = Tab(title: "t", workingDirectory: "/a")
        let before = tab.focusedPaneID
        tab.focus(PaneID())
        XCTAssertEqual(tab.focusedPaneID, before)
    }

    func testClosePaneRefocusesAndReportsLastPane() {
        let tab = Tab(title: "t", workingDirectory: "/a")
        let a = tab.focusedPaneID
        let b = tab.split(a, direction: .right, workingDirectory: "/b").id
        XCTAssertTrue(tab.closePane(b))
        XCTAssertEqual(tab.focusedPaneID, a)
        XCTAssertNil(tab.pane(b))
        XCTAssertFalse(tab.closePane(a), "closing the last pane is the caller's job (close the tab)")
        XCTAssertEqual(tab.root.leaves, [a])
    }

    func testClosingUnfocusedPaneKeepsFocus() {
        let tab = Tab(title: "t", workingDirectory: "/a")
        let a = tab.focusedPaneID
        let b = tab.split(a, direction: .right, workingDirectory: "/b").id
        let c = tab.split(b, direction: .down, workingDirectory: "/c").id
        XCTAssertTrue(tab.closePane(a))
        XCTAssertEqual(tab.focusedPaneID, c)
    }

    func testClosingFocusedPaneFocusesNearestRemainingPane() {
        let tab = Tab(title: "t", workingDirectory: "/a")
        let a = tab.focusedPaneID
        let b = tab.split(a, direction: .right, workingDirectory: "/b").id
        let c = tab.split(b, direction: .down, workingDirectory: "/c").id
        // Focused c closes: its sibling b takes its place and gets focus.
        XCTAssertTrue(tab.closePane(c))
        XCTAssertEqual(tab.focusedPaneID, b)
    }

    func testMoveFocusUsesGeometry() {
        let tab = Tab(title: "t", workingDirectory: "/a")
        let a = tab.focusedPaneID
        let b = tab.split(a, direction: .right, workingDirectory: "/b").id
        XCTAssertTrue(tab.moveFocus(.left))
        XCTAssertEqual(tab.focusedPaneID, a)
        XCTAssertFalse(tab.moveFocus(.left))
        XCTAssertTrue(tab.moveFocus(.right))
        XCTAssertEqual(tab.focusedPaneID, b)
    }

    func testListTitleUsesFolderNameWhenShellTitleIsTheDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tab = Tab(title: "~/Developer/promptty-2", workingDirectory: home + "/Developer/promptty-2")
        XCTAssertEqual(tab.listTitle, "promptty-2")
        XCTAssertEqual(tab.listSubtitle, "~/Developer/promptty-2")
    }

    func testListTitleKeepsARealCommandTitle() {
        let tab = Tab(title: "nvim notes.md", workingDirectory: "/tmp")
        XCTAssertEqual(tab.listTitle, "nvim notes.md")
        XCTAssertEqual(tab.listSubtitle, "/tmp")
    }

    func testListTitleForHomeHasNoDuplicateSubtitle() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tab = Tab(title: "~", workingDirectory: home)
        XCTAssertEqual(tab.listTitle, "~")
        XCTAssertNil(tab.listSubtitle)
    }

    func testListTitleForEmptyShellTitleAndRoot() {
        XCTAssertEqual(Tab(title: "", workingDirectory: "/tmp").listTitle, "tmp")
        let root = Tab(title: "/", workingDirectory: "/")
        XCTAssertEqual(root.listTitle, "/")
        XCTAssertNil(root.listSubtitle)
    }

    func testListTitlePrefersCustomTitle() {
        let tab = Tab(title: "/tmp", customTitle: "Logs", workingDirectory: "/tmp")
        XCTAssertEqual(tab.listTitle, "Logs")
        XCTAssertEqual(tab.listSubtitle, "/tmp")
    }

    func testEqualizeAndSetRatio() {
        let tab = Tab(title: "t", workingDirectory: "/a")
        _ = tab.split(tab.focusedPaneID, direction: .right, workingDirectory: "/b")
        tab.setRatio(at: SplitPath(steps: []), 0.7)
        guard case .split(_, let ratio, _, _) = tab.root else { return XCTFail() }
        XCTAssertEqual(ratio, 0.7)
        tab.equalize()
        guard case .split(_, let after, _, _) = tab.root else { return XCTFail() }
        XCTAssertEqual(after, 0.5)
    }
}

@MainActor
final class PaneMoveTests: XCTestCase {
    private func workspace() -> (Workspace, WindowState, Tab, Tab) {
        let ws = Workspace()
        let w = ws.addWindow()
        let t1 = w.addTab(title: "one", workingDirectory: "/1")
        let t2 = w.addTab(title: "two", workingDirectory: "/2")
        return (ws, w, t1, t2)
    }

    func testMovePaneWithinTab() {
        let (ws, _, t1, _) = workspace()
        let a = t1.focusedPaneID
        let b = t1.split(a, direction: .right, workingDirectory: "/b").id
        XCTAssertTrue(ws.movePane(a, to: b, edge: .bottom))
        XCTAssertEqual(t1.root, .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(a)))
        XCTAssertEqual(t1.focusedPaneID, a)
    }

    func testMovePaneAcrossTabsKeepsThePaneObject() {
        let (ws, w, t1, t2) = workspace()
        let a = t1.focusedPaneID
        let extra = t1.split(a, direction: .right, workingDirectory: "/x")
        let target = t2.focusedPaneID
        XCTAssertTrue(ws.movePane(extra.id, to: target, edge: .left))
        XCTAssertNil(t1.pane(extra.id))
        XCTAssertTrue(t2.pane(extra.id) === extra)
        XCTAssertEqual(t2.root.leaves, [extra.id, target])
        XCTAssertEqual(t1.root.leaves, [a])
        XCTAssertEqual(t1.focusedPaneID, a)
        XCTAssertEqual(w.selectedTabID, t2.id)
        XCTAssertEqual(t2.focusedPaneID, extra.id)
    }

    func testMovingOnlyPaneRemovesSourceTab() {
        let (ws, w, t1, t2) = workspace()
        let only = t1.focusedPaneID
        XCTAssertTrue(ws.movePane(only, to: t2.focusedPaneID, edge: .right))
        XCTAssertNil(w.tab(id: t1.id))
        XCTAssertEqual(w.tabs.count, 1)
        XCTAssertEqual(w.selectedTabID, t2.id)
        XCTAssertEqual(t2.root.leaves.count, 2)
    }

    func testMovePaneAcrossWindowsRemovesEmptiedWindowTab() {
        let ws = Workspace()
        let w1 = ws.addWindow()
        let src = w1.addTab(title: "s", workingDirectory: "/s")
        let w2 = ws.addWindow()
        let dst = w2.addTab(title: "d", workingDirectory: "/d")
        XCTAssertTrue(ws.movePane(src.focusedPaneID, to: dst.focusedPaneID, edge: .top))
        XCTAssertTrue(w1.isEmpty, "the coordinator closes the emptied window")
        XCTAssertEqual(dst.root.leaves.count, 2)
    }

    func testMovePaneOntoItselfIsRejected() {
        let (ws, _, t1, _) = workspace()
        let a = t1.focusedPaneID
        let before = t1.root
        XCTAssertFalse(ws.movePane(a, to: a, edge: .left))
        XCTAssertEqual(t1.root, before)
    }

    func testMoveUnknownPaneIsRejected() {
        let (ws, _, t1, _) = workspace()
        XCTAssertFalse(ws.movePane(PaneID(), to: t1.focusedPaneID, edge: .left))
        XCTAssertFalse(ws.movePane(t1.focusedPaneID, to: PaneID(), edge: .left))
    }

    func testMovePaneIntoTabSelectsIt() {
        let (ws, w, t1, t2) = workspace()
        let a = t1.focusedPaneID
        let extra = t1.split(a, direction: .right, workingDirectory: "/x").id
        let t2Pane = t2.focusedPaneID
        w.select(id: t1.id)
        XCTAssertTrue(ws.movePane(extra, intoTab: t2.id))
        XCTAssertEqual(t2.root.leaves, [t2Pane, extra])
        XCTAssertEqual(w.selectedTabID, t2.id)
        XCTAssertEqual(t2.focusedPaneID, extra)
    }

    func testMovePaneIntoItsOwnTabIsRejected() {
        let (ws, _, t1, _) = workspace()
        XCTAssertFalse(ws.movePane(t1.focusedPaneID, intoTab: t1.id))
    }

    func testTabContainingPane() {
        let (ws, w, _, t2) = workspace()
        let found = ws.tab(containing: t2.focusedPaneID)
        XCTAssertTrue(found?.0 === w)
        XCTAssertTrue(found?.1 === t2)
        XCTAssertNil(ws.tab(containing: PaneID()))
    }
}
