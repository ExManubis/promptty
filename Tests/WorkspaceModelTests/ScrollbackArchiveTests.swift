import XCTest
@testable import WorkspaceModel

@MainActor
final class ScrollbackArchiveTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 0)

    func testKeepsTheLastLinesWithoutTrailingBlanksThenAMarker() throws {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n\n   \n\u{1B}[0m\n"
        let archived = try XCTUnwrap(ScrollbackArchive.archived(text, savedAt: date, maxLines: 3))
        let lines = archived.components(separatedBy: "\r\n")
        XCTAssertEqual(Array(lines.prefix(3)), ["line 8", "line 9", "line 10"])
        XCTAssertTrue(archived.contains("── restored · saved "))
        XCTAssertTrue(archived.hasSuffix("\r\n"))
    }

    func testBlankLinesBetweenAreKeptAndCarriageReturnsDropped() throws {
        let text = "one\r\n\r\ntwo\nthree\r\n\n\n"
        let archived = try XCTUnwrap(ScrollbackArchive.archived(text, savedAt: date, maxLines: 3))
        XCTAssertTrue(archived.hasPrefix("\r\ntwo\r\nthree\r\n\u{1B}[0m"), archived.debugDescription)
        let all = try XCTUnwrap(ScrollbackArchive.archived("only", savedAt: date))
        XCTAssertTrue(all.hasPrefix("only\r\n"))
    }

    func testNothingToKeepForAnEmptyScreen() {
        XCTAssertNil(ScrollbackArchive.archived("\n   \n\u{1B}[0m\n", savedAt: date))
    }

    func testReplaceWritesTheNewFilesAndRemovesTheRest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = ScrollbackArchive(directory: dir)
        archive.replace(with: ["a": "one", "b": "two"])
        archive.replace(with: ["x": "five"])
        archive.replace(with: ["b": "three", "c": "four"], keeping: ["x"])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["b", "c", "x"])
        XCTAssertEqual(try String(contentsOf: archive.url(for: "b"), encoding: .utf8), "three")
    }

    func testSessionKeepsEachTabsArchiveNameAndRestoreHandsItToTheFocusedPane() throws {
        let ws = Workspace(tabLayout: .sidebar)
        let w = ws.addWindow()
        let tab = w.addTab(title: "", workingDirectory: "/tmp")
        let snapshot = ws.snapshot { $0.id == tab.focusedPaneID ? "x.vt" : nil }
        XCTAssertEqual(snapshot.windows[0].tabs[0].scrollback, "x.vt")
        let data = try JSONEncoder().encode(snapshot)
        let restored = Workspace.restore(from: try JSONDecoder().decode(SessionSnapshot.self, from: data), directoryExists: { _ in true })
        XCTAssertEqual(restored.windows[0].tabs[0].focusedPane.restoredScrollback, "x.vt")
    }
}
