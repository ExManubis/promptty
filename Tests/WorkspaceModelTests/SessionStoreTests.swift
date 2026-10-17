import XCTest
@testable import WorkspaceModel

final class SessionStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testLoadReturnsNilWhenFileMissing() {
        let store = SessionStore(url: dir.appendingPathComponent("session.json"))
        XCTAssertNil(store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = dir.appendingPathComponent("nested/session.json")
        let store = SessionStore(url: url)
        let snap = SessionSnapshot(version: 1, tabLayout: .strip, windows: [])
        try store.save(snap)
        XCTAssertEqual(store.load(), snap)
    }

    func testASplitLayoutRoundTrips() throws {
        let store = SessionStore(url: dir.appendingPathComponent("session.json"))
        let layout = ClosedLayout.split(axis: .vertical, ratio: 0.4,
                                        first: .pane(workingDirectory: "/a", focused: false, label: "server", scrollback: "a.vt"),
                                        second: .pane(workingDirectory: "/b", focused: true))
        let tab = TabSnapshot(title: "b", customTitle: nil, workingDirectory: "/b", layout: layout)
        let snap = SessionSnapshot(version: 1, tabLayout: .sidebar, windows: [WindowSnapshot(frame: nil, tabs: [tab], selectedIndex: 0)])
        try store.save(snap)
        XCTAssertEqual(store.load(), snap)
    }

    /// A file written before splits were kept (no `layout`, no `projects`) still loads.
    func testAFileFromBeforeSplitsLoads() throws {
        let url = dir.appendingPathComponent("session.json")
        try Data(#"""
        {"version": 1, "tabLayout": "sidebar", "windows": [{"tabs": [
          {"title": "zsh", "workingDirectory": "/tmp", "scrollback": "x.vt", "label": "logs"}
        ], "selectedIndex": 0}]}
        """#.utf8).write(to: url)
        let snap = try XCTUnwrap(SessionStore(url: url).load())
        XCTAssertNil(snap.windows[0].tabs[0].layout)
        XCTAssertEqual(snap.windows[0].tabs[0].scrollback, "x.vt")
        XCTAssertEqual(snap.windows[0].tabs[0].label, "logs")
    }

    func testCorruptFileIsRenamedToBakAndLoadReturnsNil() throws {
        let url = dir.appendingPathComponent("session.json")
        try Data("{ not json".utf8).write(to: url)
        let store = SessionStore(url: url)
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".bak"))
    }

    func testNewerVersionIsTreatedAsCorrupt() throws {
        let url = dir.appendingPathComponent("session.json")
        let future = SessionSnapshot(version: SessionSnapshot.currentVersion + 1, tabLayout: .sidebar, windows: [])
        try JSONEncoder().encode(future).write(to: url)
        let store = SessionStore(url: url)
        XCTAssertNil(store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".bak"))
    }
}
