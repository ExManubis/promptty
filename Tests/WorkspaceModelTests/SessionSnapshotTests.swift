import XCTest
@testable import WorkspaceModel

@MainActor
final class SessionSnapshotTests: XCTestCase {
    func testSnapshotCapturesLayoutWindowsTabsAndSelection() {
        let ws = Workspace(tabLayout: .strip)
        let w = ws.addWindow(frame: WindowFrame(x: 10, y: 20, width: 800, height: 600))
        _ = w.addTab(title: "a", workingDirectory: "/a")
        let b = w.addTab(title: "b", workingDirectory: "/b")
        b.customTitle = "renamed"
        w.select(id: b.id)

        let snap = ws.snapshot()
        XCTAssertEqual(snap.version, SessionSnapshot.currentVersion)
        XCTAssertEqual(snap.tabLayout, .strip)
        XCTAssertEqual(snap.windows.count, 1)
        XCTAssertEqual(snap.windows[0].frame, WindowFrame(x: 10, y: 20, width: 800, height: 600))
        XCTAssertEqual(snap.windows[0].tabs.map(\.title), ["a", "b"])
        XCTAssertEqual(snap.windows[0].tabs[1].customTitle, "renamed")
        XCTAssertEqual(snap.windows[0].selectedIndex, 1)
    }

    func testSnapshotOfSplitTabWritesFocusedPane() {
        let ws = Workspace()
        let w = ws.addWindow()
        let tab = w.addTab(title: "left", workingDirectory: "/left")
        let right = tab.split(tab.focusedPaneID, direction: .right, workingDirectory: "/right")
        right.title = "right"
        XCTAssertEqual(ws.snapshot().windows[0].tabs[0].title, "right")
        XCTAssertEqual(ws.snapshot().windows[0].tabs[0].workingDirectory, "/right")
        tab.focus(tab.root.leaves[0])
        XCTAssertEqual(ws.snapshot().windows[0].tabs[0].title, "left")
        XCTAssertEqual(ws.snapshot().windows[0].tabs[0].workingDirectory, "/left")
    }

    func testATabWithOnePaneHasNoLayout() {
        let ws = Workspace()
        ws.addWindow().addTab(title: "a", workingDirectory: "/a")
        XCTAssertNil(ws.snapshot().windows[0].tabs[0].layout)
    }

    /// Each pane comes back where it was, in its folder, with its label and scrollback file, and
    /// the focused one focused.
    func testASplitTabComesBackSplit() throws {
        let ws = Workspace()
        let w = ws.addWindow()
        let tab = w.addTab(title: "left", workingDirectory: "/left")
        let left = tab.focusedPane
        left.label = "server"
        let right = tab.split(left.id, direction: .right, workingDirectory: "/right")
        let below = tab.split(right.id, direction: .down, workingDirectory: "/gone")
        below.label = "logs"
        tab.setRatio(at: SplitPath(steps: []), 0.3)
        tab.focus(right.id)
        right.title = "vim"
        let files = [left.id: "l.vt", below.id: "b.vt"]
        let snap = ws.snapshot { files[$0.id] }
        XCTAssertEqual(snap.windows[0].tabs[0].scrollback, nil)

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snap))
        let restored = Workspace.restore(from: decoded, directoryExists: { $0 != "/gone" }, fallbackDirectory: "/home").windows[0].tabs[0]
        XCTAssertEqual(restored.root.leaves.count, 3)
        guard case .split(.horizontal, let ratio, .leaf, .split(.vertical, _, .leaf, .leaf)) = restored.root else {
            return XCTFail("\(restored.root)")
        }
        XCTAssertEqual(ratio, 0.3, accuracy: 0.001)
        let panes = restored.orderedPanes
        XCTAssertEqual(panes.map(\.workingDirectory), ["/left", "/right", "/home"])
        XCTAssertEqual(panes.map(\.label), ["server", nil, "logs"])
        XCTAssertEqual(panes.map(\.restoredScrollback), ["l.vt", nil, "b.vt"])
        XCTAssertEqual(restored.focusedPaneID, panes[1].id)
        XCTAssertEqual(restored.title, "vim")
    }

    /// A pinned tab comes back as its pin, one pane, whatever it was split into.
    func testASplitPinnedTabComesBackAsItsPin() {
        let ws = Workspace()
        let w = ws.addWindow()
        let tab = w.addTab(title: "", workingDirectory: "/repo")
        _ = tab.split(tab.focusedPaneID, direction: .right, workingDirectory: "/other")
        w.pin(tab.id, TabPin(directory: "/repo", command: "claude"))
        let restored = Workspace.restore(from: ws.snapshot(), directoryExists: { _ in true }).windows[0].tabs[0]
        XCTAssertFalse(restored.hasSplits)
        XCTAssertEqual(restored.workingDirectory, "/repo")
        XCTAssertEqual(restored.focusedPane.startupCommand, "claude")
    }

    func testRoundTripThroughJSON() throws {
        let ws = Workspace()
        let w = ws.addWindow()
        _ = w.addTab(title: "a", workingDirectory: "/a")
        let snap = ws.snapshot()
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testRestoreRebuildsWorkspace() {
        let snap = SessionSnapshot(
            version: SessionSnapshot.currentVersion,
            tabLayout: .strip,
            windows: [
                WindowSnapshot(
                    frame: nil,
                    tabs: [TabSnapshot(title: "a", customTitle: nil, workingDirectory: "/a"),
                           TabSnapshot(title: "b", customTitle: "B", workingDirectory: "/b")],
                    selectedIndex: 0
                ),
            ]
        )
        let ws = Workspace.restore(from: snap, directoryExists: { _ in true })
        XCTAssertEqual(ws.tabLayout, .strip)
        XCTAssertEqual(ws.windows.count, 1)
        XCTAssertEqual(ws.windows[0].tabs.map(\.displayTitle), ["a", "B"])
        XCTAssertEqual(ws.windows[0].selectedTab?.title, "a")
    }

    func testRestoreFallsBackToHomeForMissingDirectories() {
        let snap = SessionSnapshot(
            version: 1, tabLayout: .sidebar,
            windows: [WindowSnapshot(frame: nil,
                                     tabs: [TabSnapshot(title: "x", customTitle: nil, workingDirectory: "/gone")],
                                     selectedIndex: 0)]
        )
        let ws = Workspace.restore(from: snap, directoryExists: { $0 != "/gone" }, fallbackDirectory: "/Users/me")
        XCTAssertEqual(ws.windows[0].tabs[0].workingDirectory, "/Users/me")
    }

    func testRestoreWithNoWindowsYieldsOneWindowWithOneTab() {
        let snap = SessionSnapshot(version: 1, tabLayout: .sidebar, windows: [])
        let ws = Workspace.restore(from: snap, directoryExists: { _ in true }, fallbackDirectory: "/Users/me")
        XCTAssertEqual(ws.windows.count, 1)
        XCTAssertEqual(ws.windows[0].tabs.count, 1)
        XCTAssertEqual(ws.windows[0].tabs[0].workingDirectory, "/Users/me")
    }

    func testRestoreClampsInvalidSelectedIndex() {
        let snap = SessionSnapshot(
            version: 1, tabLayout: .sidebar,
            windows: [WindowSnapshot(frame: nil,
                                     tabs: [TabSnapshot(title: "x", customTitle: nil, workingDirectory: "/")],
                                     selectedIndex: 7)]
        )
        let ws = Workspace.restore(from: snap, directoryExists: { _ in true })
        XCTAssertEqual(ws.windows[0].selectedTab?.title, "x")
    }

    func testRestoreSkipsWindowsWithoutTabs() {
        let snap = SessionSnapshot(
            version: 1, tabLayout: .sidebar,
            windows: [WindowSnapshot(frame: nil, tabs: [], selectedIndex: nil),
                      WindowSnapshot(frame: nil,
                                     tabs: [TabSnapshot(title: "a", customTitle: nil, workingDirectory: "/a")],
                                     selectedIndex: 0)]
        )
        let ws = Workspace.restore(from: snap, directoryExists: { _ in true })
        XCTAssertEqual(ws.windows.count, 1)
        XCTAssertEqual(ws.windows[0].tabs.map(\.title), ["a"])
    }

    func testRestoreWithOnlyTablessWindowsYieldsOneWindowWithOneTab() {
        let snap = SessionSnapshot(
            version: 1, tabLayout: .sidebar,
            windows: [WindowSnapshot(frame: nil, tabs: [], selectedIndex: nil),
                      WindowSnapshot(frame: nil, tabs: [], selectedIndex: nil)]
        )
        let ws = Workspace.restore(from: snap, directoryExists: { _ in true }, fallbackDirectory: "/Users/me")
        XCTAssertEqual(ws.windows.count, 1)
        XCTAssertEqual(ws.windows[0].tabs.count, 1)
        XCTAssertEqual(ws.windows[0].tabs[0].workingDirectory, "/Users/me")
    }
}
