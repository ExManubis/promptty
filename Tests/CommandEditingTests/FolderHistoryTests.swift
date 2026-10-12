import CommandEditing
import XCTest

final class FolderHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func history(_ items: [(String, String)]) -> FolderHistory {
        var h = FolderHistory()
        for (i, (dir, command)) in items.enumerated() {
            h.add(command: command, directory: dir, date: t0.addingTimeInterval(Double(i)))
        }
        return h
    }

    func testThisFoldersCommandsComeFirstNewestFirst() {
        let h = history([("/web", "npm run dev"), ("/app", "swift test"), ("/web", "npm test"), ("/app", "swift build")])
        XCTAssertEqual(h.ranked(for: "/app"), ["swift build", "swift test"])
    }

    func testParentFoldersFollowNearestFirst() {
        let h = history([("/repo", "swift test"), ("/", "ls"), ("/repo/Sources", "vim main.swift"), ("/other", "make")])
        XCTAssertEqual(h.ranked(for: "/repo/Sources/App"), ["vim main.swift", "swift test", "ls"])
    }

    func testAFolderOnlySharingAPrefixIsNotAParent() {
        let h = history([("/repo", "swift test"), ("/repo-old", "make")])
        XCTAssertEqual(h.ranked(for: "/repo-old/x"), ["make"])
    }

    func testRepeatsCountOnceAtTheirNewestPlace() {
        let h = history([("/app", "swift test"), ("/app", "swift build"), ("/app", "swift test")])
        XCTAssertEqual(h.ranked(for: "/app"), ["swift test", "swift build"])
    }

    func testCommandsWithALeadingSpaceOrEmptyAreNotKept() {
        let h = history([("/app", " secret --token x"), ("/app", "   "), ("/app", "make")])
        XCTAssertEqual(h.ranked(for: "/app"), ["make"])
    }

    func testOnlyTheNewestEntriesAreKept() {
        var h = FolderHistory()
        for i in 0..<(FolderHistory.limit + 10) {
            h.add(command: "c\(i)", directory: "/d", date: t0)
        }
        XCTAssertEqual(h.entries.count, FolderHistory.limit)
        XCTAssertEqual(h.entries.last?.command, "c\(FolderHistory.limit + 9)")
    }

    func testRoundTripsThroughJSONLinesAndSkipsBrokenLines() throws {
        let h = history([("/a b", "echo \"x\ty\"\nls"), ("/c", "make")])
        var data = Data()
        for entry in h.entries { data += FolderHistory.line(for: entry) }
        data += Data("not json\n".utf8)
        let decoded = FolderHistory.decode(data)
        XCTAssertEqual(decoded.entries, h.entries)
    }

    func testThisFolderSuggestsBeforeTheGlobalHistory() {
        let h = history([("/app", "swift test --parallel")])
        let global = ["swift test --filter Foo", "swift build"]
        XCTAssertEqual(Autosuggester.suggestion(for: "swift t", local: h.ranked(for: "/app"), history: global), "est --parallel")
        XCTAssertEqual(Autosuggester.suggestion(for: "swift b", local: h.ranked(for: "/app"), history: global), "uild")
        XCTAssertNil(Autosuggester.suggestion(for: "make", local: [], history: global))
    }
}
