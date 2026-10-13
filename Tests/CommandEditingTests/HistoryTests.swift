import XCTest
@testable import CommandEditing

final class ZshHistoryTests: XCTestCase {
    private func parse(_ bytes: [UInt8]) -> [String] { ZshHistory.parse(Data(bytes)) }
    private func parse(_ text: String) -> [String] { ZshHistory.parse(Data(text.utf8)) }

    func testExtendedFormat() {
        XCTAssertEqual(parse(": 1700000000:0;git status\n: 1700000001:3;make test\n"), ["git status", "make test"])
    }

    func testPlainLines() {
        XCTAssertEqual(parse("ls\ncd ~\n"), ["ls", "cd ~"])
    }

    func testMultiLineEntries() {
        XCTAssertEqual(parse(": 1:0;for x in 1 2\\\ndo echo $x\\\ndone\n: 2:0;ls\n"), ["for x in 1 2\ndo echo $x\ndone", "ls"])
    }

    func testMetafiedBytesAreRestored() {
        // "echo →": → is E2 86 92; zsh writes 0x86 and 0x92 as 0x83 followed by the byte xor 0x20.
        let bytes: [UInt8] = Array(": 1:0;echo ".utf8) + [0xE2, 0x83, 0xA6, 0x83, 0xB2] + [0x0A]
        XCTAssertEqual(parse(bytes), ["echo →"])
    }

    func testPlainUTF8PassesThrough() {
        XCTAssertEqual(parse(": 1:0;echo café\n"), ["echo café"])
    }

    func testBlankLinesAndMissingFinalNewline() {
        XCTAssertEqual(parse("\n: 1:0;a\n\n: 2:0;b"), ["a", "b"])
    }

    func testMalformedExtendedHeaderIsKeptAsText() {
        XCTAssertEqual(parse(": not a header\n"), [": not a header"])
    }
}

@MainActor
final class CommandHistoryTests: XCTestCase {
    func testNewestFirstWithoutDuplicates() {
        let h = CommandHistory(fileEntries: ["ls", "git status", "ls", "make"])
        XCTAssertEqual(h.newestFirst, ["make", "ls", "git status"])
        h.add("git status")
        XCTAssertEqual(h.newestFirst, ["git status", "make", "ls"])
    }

    func testAddPutsACommandOnTopAndDropsItsOlderCopies() {
        let h = CommandHistory(fileEntries: ["a", "b", "c"])
        h.add("x")
        h.add("y")
        h.add("x")
        XCTAssertEqual(h.newestFirst, ["x", "y", "c", "b", "a"])
        h.add("b")
        XCTAssertEqual(h.newestFirst, ["b", "x", "y", "c", "a"])
        h.add("b")
        XCTAssertEqual(h.newestFirst, ["b", "x", "y", "c", "a"])
    }

    func testManyRepeatedAddsStayCorrect() {
        let h = CommandHistory(fileEntries: (0..<10).map { "f\($0)" })
        for round in 0..<500 { h.add("s\(round % 3)") }
        XCTAssertEqual(Array(h.newestFirst.prefix(3)), ["s1", "s0", "s2"])
        XCTAssertEqual(h.newestFirst.count, 13)
    }

    func testAddAndReadNeverMergesTheWholeHistory() {
        let h = CommandHistory(fileEntries: (0..<50_000).map { "command \($0)" })
        let start = Date()
        var suggester = IncrementalSuggester()
        for i in 0..<2_000 {
            h.add("session \(i % 100)")
            // What Enter and the next keys do: take the walkable list, scan it, start a walk.
            XCTAssertEqual(suggester.suggestion(for: "session", local: [], history: h.merged, generation: h.version) != nil, true)
            var walk = HistoryNavigator(history: h.merged)
            XCTAssertEqual(walk.older(current: ""), "session \(i % 100)")
        }
        XCTAssertEqual(h.mergeCount, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertEqual(h.newestFirst.count, 50_100)
        XCTAssertEqual(h.mergeCount, 1)
    }

    func testMergedWalksSessionThenFileWithoutShadowedEntries() {
        let h = CommandHistory(fileEntries: ["a", "b", "c"])
        h.add("b")
        h.add("x")
        XCTAssertEqual(Array(h.merged), ["x", "b", "c", "a"])
        XCTAssertEqual(Array(h.merged), h.newestFirst)
        var walk = HistoryNavigator(history: h.merged)
        XCTAssertEqual([walk.older(current: "d"), walk.older(current: "d"), walk.older(current: "d"), walk.older(current: "d"), walk.older(current: "d")], ["x", "b", "c", "a", nil])
        XCTAssertEqual(walk.newer(), "c")
    }

    func testPanesSharingAStoreKeepTheirOwnCommands() {
        let store = HistoryStore(entries: ["a", "b"])
        let one = CommandHistory(store: store)
        let two = CommandHistory(store: store)
        one.add("only-one")
        XCTAssertEqual(one.newestFirst, ["only-one", "b", "a"])
        XCTAssertEqual(two.newestFirst, ["b", "a"])
        store.appendFile(["c"])
        XCTAssertEqual(one.newestFirst, ["only-one", "c", "b", "a"])
        XCTAssertEqual(two.newestFirst, ["c", "b", "a"])
    }

    func testMovingToAnotherStoreKeepsThePanesOwnCommands() {
        let h = CommandHistory(fileEntries: [])
        h.add("mine")
        h.use(HistoryStore(entries: ["f"]))
        XCTAssertEqual(h.newestFirst, ["mine", "f"])
    }

    func testLargeHistoriesAreReadyWithoutRecomputing() {
        let entries = (0..<100_000).map { "command \($0 % 50_000)" }
        let h = CommandHistory(fileEntries: entries)
        // Read on every keystroke (ghost text): must not rebuild the list each time.
        let start = Date()
        for _ in 0..<100 { _ = h.merged.first(where: { _ in true }) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
        XCTAssertEqual(h.newestFirst.count, 50_000)
        XCTAssertEqual(h.newestFirst.first, "command 49999")
    }

    func testCommandsStartingWithASpaceStayOutOfHistory() {
        let h = CommandHistory(fileEntries: [])
        h.add(" export TOKEN=secret")
        XCTAssertTrue(h.newestFirst.isEmpty, "zsh's HIST_IGNORE_SPACE convention, used for secrets")
    }

    func testBlankCommandsAreNotAdded() {
        let h = CommandHistory(fileEntries: [])
        h.add("   ")
        h.add("")
        XCTAssertTrue(h.newestFirst.isEmpty)
    }

    func testReplacingFileEntriesKeepsSessionCommandsOnTop() {
        let h = CommandHistory(fileEntries: ["a"])
        h.add("mine")
        h.replaceFileEntries(["a", "b"])
        XCTAssertEqual(h.newestFirst, ["mine", "b", "a"])
    }

    func testAppendingFileEntriesIsTheSameAsReplacingWithTheLongerFile() {
        let grown = CommandHistory(fileEntries: ["a", "b", "a"])
        grown.add("mine")
        grown.appendFileEntries(["c", "b", "d"])
        let replaced = CommandHistory(fileEntries: ["a", "b", "a"])
        replaced.add("mine")
        replaced.replaceFileEntries(["a", "b", "a", "c", "b", "d"])
        XCTAssertEqual(grown.newestFirst, replaced.newestFirst)
        XCTAssertEqual(grown.newestFirst, ["mine", "d", "b", "c", "a"])
    }

    func testASessionCommandWinsOverTheSameCommandLaterInTheFile() {
        let h = CommandHistory(fileEntries: ["a"])
        h.add("x")
        h.appendFileEntries(["x", "b"])
        XCTAssertEqual(h.newestFirst, ["x", "b", "a"])
    }

    func testVersionChangesOnlyWhenTheListDoes() {
        let h = CommandHistory(fileEntries: ["a"])
        let v = h.version
        h.add(" secret")
        h.appendFileEntries([])
        XCTAssertEqual(h.version, v)
        h.add("b")
        XCTAssertNotEqual(h.version, v)
    }
}

final class HistoryStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ text: String, to name: String = "hist") throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    private func append(_ text: String, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @MainActor func testOneStorePerPathWhileAnyoneHoldsIt() throws {
        let path = try write("a\n")
        var first: HistoryStore? = HistoryStore.shared(forPath: path)
        let second = HistoryStore.shared(forPath: path)
        XCTAssertTrue(first === second)
        XCTAssertFalse(first === HistoryStore.shared(forPath: try write("b\n", to: "other")))
        weak var weakFirst = first
        first = nil
        XCTAssertNotNil(weakFirst, "still held by the second pane")
        _ = second
    }

    @MainActor func testStoreEndsWhenTheLastPaneLetsGo() throws {
        let path = try write("a\n")
        weak var weakStore: HistoryStore?
        do {
            let store = HistoryStore.shared(forPath: path)
            weakStore = store
            XCTAssertNotNil(weakStore)
        }
        XCTAssertNil(weakStore)
        XCTAssertNotNil(HistoryStore.shared(forPath: path))
    }

    @MainActor func testTildeAndPlainPathsShareAStore() {
        let a = HistoryStore.shared(forPath: "~/.zsh_history_test_shared")
        let b = HistoryStore.shared(forPath: (NSHomeDirectory() as NSString).appendingPathComponent(".zsh_history_test_shared"))
        XCTAssertTrue(a === b)
    }

    @MainActor func testReloadReadsTheFileAndKeepsSessionOnTop() async throws {
        let path = try write(": 1:0;ls\n: 2:0;make\n: 3:0;ls\n")
        let store = HistoryStore.shared(forPath: path)
        let pane = CommandHistory(store: store)
        pane.add("mine")
        await store.reload()
        XCTAssertEqual(pane.newestFirst, ["mine", "ls", "make"])
    }

    @MainActor func testGrowthIsReadFromTheEndAndTruncationReadsAgain() async throws {
        let path = try write("a\nb\n")
        let store = HistoryStore.shared(forPath: path)
        await store.reload()
        XCTAssertEqual(store.newestFirst, ["b", "a"])
        try append("c\na\n", to: path)
        await store.reload()
        XCTAssertEqual(store.newestFirst, ["a", "c", "b"])
        XCTAssertEqual(store.lastReloadWasIncremental, true)
        try Data("z\n".utf8).write(to: URL(fileURLWithPath: path))
        await store.reload()
        XCTAssertEqual(store.newestFirst, ["z"])
        XCTAssertEqual(store.lastReloadWasIncremental, false)
    }

    @MainActor func testARewriteOfTheSameOrLargerSizeIsNoticed() async throws {
        let path = try write("aaaa\nbbbb\n")
        let store = HistoryStore.shared(forPath: path)
        await store.reload()
        try Data("cccc\ndddd\neeee\n".utf8).write(to: URL(fileURLWithPath: path))
        await store.reload()
        XCTAssertEqual(store.newestFirst, ["eeee", "dddd", "cccc"])
    }

    @MainActor func testAHalfWrittenLastLineIsCompletedLater() async throws {
        let path = try write("a\nlong comm")
        let store = HistoryStore.shared(forPath: path)
        await store.reload()
        try append("and\nb\n", to: path)
        await store.reload()
        XCTAssertEqual(store.newestFirst, ["b", "long command", "a"])
    }

    @MainActor func testMultiLineCommandsAcrossAnIncrementalReload() async throws {
        let path = try write("a\nfor x in 1\\\n")
        let store = HistoryStore.shared(forPath: path)
        await store.reload()
        try append("do echo\\\ndone\nb\n", to: path)
        await store.reload()
        XCTAssertEqual(store.newestFirst.first, "b")
        XCTAssertTrue(store.newestFirst.contains("for x in 1\ndo echo\ndone"))
    }

    @MainActor func testARenamedReplacementOfTheSameShapeIsReadInFull() async throws {
        let path = try write("aaaa\nbbbb\n")
        let store = HistoryStore.shared(forPath: path)
        await store.reload()
        XCTAssertEqual(store.newestFirst, ["bbbb", "aaaa"])
        // zsh writes a temporary file and renames it over the history; the tail looks the same.
        let temp = dir.appendingPathComponent("hist.new")
        try Data("xxxx\nbbbb\ncccc\n".utf8).write(to: temp)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: temp)
        await store.reload()
        XCTAssertEqual(store.newestFirst, ["cccc", "bbbb", "xxxx"])
        XCTAssertEqual(store.lastReloadWasIncremental, false)
    }

    @MainActor func testStoreLookupDoesNotDisturbLiveStores() throws {
        let path = try write("a\n")
        let store = HistoryStore.shared(forPath: path)
        for i in 0..<20 { _ = HistoryStore.shared(forPath: dir.appendingPathComponent("f\(i)").path) }
        XCTAssertTrue(HistoryStore.shared(forPath: path) === store)
    }

    @MainActor func testPanesWithDifferentFilesKeepSeparateHistory() async throws {
        let one = HistoryStore.shared(forPath: try write("a\n", to: "one"))
        let two = HistoryStore.shared(forPath: try write("b\n", to: "two"))
        await one.reload()
        await two.reload()
        XCTAssertEqual(one.newestFirst, ["a"])
        XCTAssertEqual(two.newestFirst, ["b"])
    }

    @MainActor func testOverlappingReloadsAreCoalesced() async throws {
        let path = try write("a\n")
        let store = HistoryStore.shared(forPath: path)
        async let first: Void = store.reload()
        async let second: Void = store.reload()
        async let third: Void = store.reload()
        _ = await (first, second, third)
        XCTAssertEqual(store.newestFirst, ["a"])
        XCTAssertLessThanOrEqual(store.reloadCount, 2)
    }

    @MainActor func testAMissingFileLeavesTheSessionAlone() async {
        let store = HistoryStore.shared(forPath: dir.appendingPathComponent("nope").path)
        let pane = CommandHistory(store: store)
        pane.add("x")
        await store.reload()
        XCTAssertEqual(pane.newestFirst, ["x"])
    }
}

final class HistoryNavigatorTests: XCTestCase {
    func testWalksOlderThenBackToTheDraft() {
        var n = HistoryNavigator(history: ["make", "ls"])
        XCTAssertEqual(n.older(current: "draft"), "make")
        XCTAssertEqual(n.older(current: "make"), "ls")
        XCTAssertNil(n.older(current: "ls"), "no older entry")
        XCTAssertEqual(n.newer(), "make")
        XCTAssertEqual(n.newer(), "draft")
        XCTAssertNil(n.newer(), "already at the draft")
    }

    func testEmptyHistory() {
        var n = HistoryNavigator(history: [])
        XCTAssertNil(n.older(current: "x"))
        XCTAssertNil(n.newer())
    }

    func testIsBrowsing() {
        var n = HistoryNavigator(history: ["a"])
        XCTAssertFalse(n.isBrowsing)
        _ = n.older(current: "")
        XCTAssertTrue(n.isBrowsing)
        _ = n.newer()
        XCTAssertFalse(n.isBrowsing)
    }
}
