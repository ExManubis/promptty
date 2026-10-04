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
}
