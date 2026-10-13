import CommandEditing
import XCTest

final class PathCommandCacheTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testOneScanPerDistinctPathAcrossManyRequests() async {
        let counter = Counter()
        let cache = PathCommandCache { path in
            counter.hit()
            Thread.sleep(forTimeInterval: 0.05)
            return Set(path.map { ($0 as NSString).lastPathComponent })
        }
        let results = await withTaskGroup(of: Set<String>.self) { group in
            for _ in 0..<10 { group.addTask { await cache.commands(on: ["/usr/bin", "/bin"]) } }
            var all: [Set<String>] = []
            for await r in group { all.append(r) }
            return all
        }
        XCTAssertTrue(results.allSatisfy { $0 == ["bin"] })
        XCTAssertEqual(counter.count, 1)
        _ = await cache.commands(on: ["/usr/bin", "/bin"])
        XCTAssertEqual(counter.count, 1)
        let other = await cache.commands(on: ["/usr/local/bin"])
        XCTAssertEqual(other, ["bin"])
        XCTAssertEqual(counter.count, 2)
    }

    func testExecutablesListsOnlyExecutableFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("promptty-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("tool"), note = dir.appendingPathComponent("note")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try "text".write(to: note, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: note.path)
        XCTAssertEqual(PathCommandCache.executables(in: [dir.path, "/nonexistent"]), ["tool"])
    }
}
