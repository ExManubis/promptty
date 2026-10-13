import XCTest
@testable import WorkspaceModel

@MainActor
final class PinnedTabTests: XCTestCase {
    private func window(tabCount: Int) -> WindowState {
        let w = WindowState()
        for i in 0..<tabCount { _ = w.addTab(title: "t\(i)", workingDirectory: "/tmp/\(i)") }
        return w
    }

    private func titles(_ w: WindowState) -> [String] { w.tabs.map(\.title) }

    // MARK: Pinning

    func testPinningMovesTheTabToTheEndOfThePinnedTabs() {
        let w = window(tabCount: 4)
        w.pin(w.tabs[2].id, TabPin(directory: "/tmp/2", command: nil))
        XCTAssertEqual(titles(w), ["t2", "t0", "t1", "t3"])
        w.pin(w.tabs[3].id, TabPin(directory: "/tmp/3", command: "npm run dev"))
        XCTAssertEqual(titles(w), ["t2", "t3", "t0", "t1"])
        XCTAssertEqual(w.pinnedCount, 2)
        XCTAssertEqual(w.tabs[1].pin, TabPin(directory: "/tmp/3", command: "npm run dev"))
    }

    func testPinningAtAnIndexStaysAmongThePinnedTabs() {
        let w = window(tabCount: 4)
        w.pin(w.tabs[0].id, TabPin(directory: "/a", command: nil))
        w.pin(w.tabs[1].id, TabPin(directory: "/b", command: nil))
        w.pin(w.tabs[3].id, TabPin(directory: "/d", command: nil), at: 0)
        XCTAssertEqual(titles(w), ["t3", "t0", "t1", "t2"])
        w.pin(w.tabs[3].id, TabPin(directory: "/c", command: nil), at: 99)
        XCTAssertEqual(titles(w), ["t3", "t0", "t1", "t2"], "clamped to the end of the pinned tabs")
    }

    func testPinningKeepsTheSelection() {
        let w = window(tabCount: 3)
        let selected = w.selectedTabID
        w.pin(w.tabs[0].id, TabPin(directory: "/a", command: nil))
        XCTAssertEqual(w.selectedTabID, selected)
    }

    func testUnpinningMovesTheTabToTheTopOfTheOtherTabs() {
        let w = window(tabCount: 3)
        w.pin(w.tabs[1].id, TabPin(directory: "/1", command: nil))
        w.pin(w.tabs[2].id, TabPin(directory: "/2", command: nil))
        XCTAssertEqual(titles(w), ["t1", "t2", "t0"])
        w.unpin(w.tabs[0].id)
        XCTAssertEqual(titles(w), ["t2", "t1", "t0"])
        XCTAssertNil(w.tabs[1].pin)
        XCTAssertEqual(w.pinnedCount, 1)
    }

    func testUnpinningAtAnIndexStaysAmongTheOtherTabs() {
        let w = window(tabCount: 3)
        w.pin(w.tabs[0].id, TabPin(directory: "/0", command: nil))
        w.pin(w.tabs[1].id, TabPin(directory: "/1", command: nil))
        w.unpin(w.tabs[0].id, at: 99)
        XCTAssertEqual(titles(w), ["t1", "t2", "t0"])
        w.pin(w.tabs[2].id, TabPin(directory: "/0", command: nil))
        w.unpin(w.tabs[0].id, at: 0)
        XCTAssertEqual(titles(w), ["t0", "t1", "t2"], "clamped to the first place after the pinned tabs")
    }

    func testUnpinningAnUnpinnedTabChangesNothing() {
        let w = window(tabCount: 2)
        w.unpin(w.tabs[1].id)
        XCTAssertEqual(titles(w), ["t0", "t1"])
    }

    func testThePinnedCommandCanBeChangedAndCleared() {
        let w = window(tabCount: 1)
        let id = w.tabs[0].id
        w.pin(id, TabPin(directory: "/a", command: "claude"))
        w.setPinnedCommand(id, "  npm run dev ")
        XCTAssertEqual(w.tabs[0].pin?.command, "npm run dev")
        w.setPinnedCommand(id, "   ")
        XCTAssertEqual(w.tabs[0].pin, TabPin(directory: "/a", command: nil))
        w.unpin(id)
        w.setPinnedCommand(id, "ls")
        XCTAssertNil(w.tabs[0].pin, "only a pinned tab has a command")
    }

    // MARK: The other tabs never mix in

    func testANewTabNeverLandsAmongThePinnedTabs() {
        let w = window(tabCount: 2)
        w.pin(w.tabs[0].id, TabPin(directory: "/0", command: nil))
        w.pin(w.tabs[1].id, TabPin(directory: "/1", command: nil))
        w.select(id: w.tabs[0].id)
        let new = w.addTab(title: "new", workingDirectory: "/n")
        XCTAssertEqual(titles(w), ["t0", "t1", "new"])
        XCTAssertNil(new.pin)
    }

    func testMovingATabStaysInItsOwnGroup() {
        let w = window(tabCount: 4)
        w.pin(w.tabs[0].id, TabPin(directory: "/0", command: nil))
        w.pin(w.tabs[1].id, TabPin(directory: "/1", command: nil))
        w.moveTab(id: w.tabs[3].id, to: 0)
        XCTAssertEqual(titles(w), ["t0", "t1", "t3", "t2"])
        w.moveTab(id: w.tabs[0].id, to: 3)
        XCTAssertEqual(titles(w), ["t1", "t0", "t3", "t2"])
        w.select(id: w.tabs[1].id)
        XCTAssertFalse(w.moveSelectedTab(by: 1), "a pinned tab does not move past the last pinned tab")
    }

    func testGotoCountsThePinnedTabsFirst() {
        let w = window(tabCount: 3)
        w.pin(w.tabs[2].id, TabPin(directory: "/2", command: nil))
        XCTAssertTrue(w.gotoTab(.index(1)))
        XCTAssertEqual(w.selectedTab?.title, "t2")
    }

    // MARK: Panes

    func testResetLeavesOneFreshPaneInTheGivenFolder() {
        let w = window(tabCount: 1)
        let tab = w.tabs[0]
        let first = tab.focusedPaneID
        let second = tab.split(first, direction: .right, workingDirectory: "/x").id
        let removed = tab.reset(workingDirectory: "/pinned", startupCommand: "claude")
        XCTAssertEqual(Set(removed), [first, second])
        XCTAssertEqual(tab.panes.count, 1)
        XCTAssertFalse(removed.contains(tab.focusedPaneID))
        XCTAssertEqual(tab.workingDirectory, "/pinned")
        XCTAssertEqual(tab.focusedPane.startupCommand, "claude")
        XCTAssertEqual(tab.root, .leaf(tab.focusedPaneID))
    }

    func testThePinnedTabsOnlyPaneCannotBeMovedOut() {
        let ws = Workspace()
        let w = ws.addWindow()
        let pinned = w.addTab(title: "p", workingDirectory: "/p")
        let other = w.addTab(title: "o", workingDirectory: "/o")
        w.pin(pinned.id, TabPin(directory: "/p", command: nil))
        XCTAssertFalse(ws.movePane(pinned.focusedPaneID, to: other.focusedPaneID, edge: .right))
        XCTAssertNotNil(w.tab(id: pinned.id))
        XCTAssertEqual(other.panes.count, 1)
        // With a split, one of its panes can go.
        let extra = pinned.split(pinned.focusedPaneID, direction: .right, workingDirectory: "/p").id
        XCTAssertTrue(ws.movePane(extra, to: other.focusedPaneID, edge: .right))
    }

    // MARK: Session

    func testSnapshotWritesThePin() {
        let ws = Workspace()
        let w = ws.addWindow()
        let tab = w.addTab(title: "a", workingDirectory: "/elsewhere")
        w.pin(tab.id, TabPin(directory: "/a", command: "claude"))
        XCTAssertEqual(ws.snapshot().windows[0].tabs[0].pin, TabPin(directory: "/a", command: "claude"))
    }

    func testRestoreOpensPinnedTabsInTheirPinnedFolderWithTheirCommand() {
        let snap = SessionSnapshot(
            version: 1, tabLayout: .sidebar,
            windows: [WindowSnapshot(frame: nil, tabs: [
                TabSnapshot(title: "x", customTitle: nil, workingDirectory: "/x"),
                TabSnapshot(title: "p", customTitle: nil, workingDirectory: "/cdd-away",
                            pin: TabPin(directory: "/pinned", command: "npm run dev")),
            ], selectedIndex: 0)]
        )
        let ws = Workspace.restore(from: snap, directoryExists: { _ in true })
        let tabs = ws.windows[0].tabs
        XCTAssertEqual(tabs.map(\.title), ["p", "x"], "pinned tabs come first")
        XCTAssertEqual(tabs[0].workingDirectory, "/pinned")
        XCTAssertEqual(tabs[0].pin, TabPin(directory: "/pinned", command: "npm run dev"))
        XCTAssertEqual(tabs[0].focusedPane.startupCommand, "npm run dev")
        XCTAssertNil(tabs[1].focusedPane.startupCommand)
        XCTAssertEqual(ws.windows[0].selectedTab?.title, "x", "the selection follows the tab")
    }

    func testRestoreKeepsAPinWhoseFolderIsGone() {
        let snap = SessionSnapshot(
            version: 1, tabLayout: .sidebar,
            windows: [WindowSnapshot(frame: nil, tabs: [
                TabSnapshot(title: "p", customTitle: nil, workingDirectory: "/gone",
                            pin: TabPin(directory: "/gone", command: "make")),
            ], selectedIndex: 0)]
        )
        let ws = Workspace.restore(from: snap, directoryExists: { $0 != "/gone" }, fallbackDirectory: "/Users/me")
        let tab = ws.windows[0].tabs[0]
        XCTAssertEqual(tab.workingDirectory, "/Users/me")
        XCTAssertEqual(tab.pin?.directory, "/gone", "the volume may come back")
        XCTAssertNil(tab.focusedPane.startupCommand, "the command was meant for its folder")
    }

    func testASessionFileWithoutPinsStillLoads() throws {
        let json = """
        {"version":1,"tabLayout":"sidebar","windows":[{"tabs":[{"title":"a","workingDirectory":"/a"}],"selectedIndex":0}]}
        """
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.windows[0].tabs[0].pin)
    }
}
