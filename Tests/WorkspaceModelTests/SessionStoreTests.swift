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
