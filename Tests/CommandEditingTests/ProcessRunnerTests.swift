import CommandEditing
import Darwin
import XCTest

final class ProcessRunnerTests: XCTestCase {
    func testAFastCommandReturnsItsOutput() async {
        let out = await ProcessRunner.run("/bin/echo", ["hello"], timeout: 5)
        XCTAssertEqual(out, "hello\n")
    }

    func testAFailingCommandReturnsNil() async {
        let out = await ProcessRunner.run("/usr/bin/false", [], timeout: 5)
        XCTAssertNil(out)
    }

    func testAMissingProgramReturnsNil() async {
        let out = await ProcessRunner.run("/nonexistent/program", [], timeout: 5)
        XCTAssertNil(out)
    }

    func testATimeoutReturnsNilQuicklyAndTerminatesTheProcess() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("promptty-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let start = Date()
        let out = await ProcessRunner.run("/bin/sh", ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 5"], timeout: 0.3)
        XCTAssertNil(out)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // Gone (or about to be reaped) shortly after the timeout.
        var alive = true
        for _ in 0..<50 where alive {
            // kill(pid, 0) still succeeds for a zombie; the runner's Process reaps it.
            alive = kill(pid, 0) == 0
            if alive { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertFalse(alive)
    }

    func testLargeOutputIsReadCompletely() async {
        // 20,000 lines of 41 bytes is 820 KB, well over a pipe's 64 KB buffer.
        let big = await ProcessRunner.run("/bin/sh", ["-c", "i=0; while [ $i -lt 20000 ]; do echo 0123456789abcdefghij0123456789abcdefghij; i=$((i+1)); done"], timeout: 20)
        XCTAssertEqual(big?.utf8.count, 20000 * 41)
    }

    func testManyRunsAtOnceDoNotStarveEachOther() async {
        let results = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<40 { group.addTask { await ProcessRunner.run("/bin/sleep", ["0.3"], timeout: 5) } }
            var all: [String?] = []
            for await r in group { all.append(r) }
            return all
        }
        XCTAssertEqual(results.count, 40)
        XCTAssertTrue(results.allSatisfy { $0 == "" })
    }
}
