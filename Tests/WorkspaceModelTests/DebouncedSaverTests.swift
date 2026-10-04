import XCTest
@testable import WorkspaceModel

@MainActor
final class DebouncedSaverTests: XCTestCase {
    func testManySchedulesCoalesceIntoOneAction() async throws {
        var count = 0
        let saver = DebouncedSaver(delay: .milliseconds(50)) { count += 1 }
        for _ in 0..<10 { saver.schedule() }
        XCTAssertEqual(count, 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(count, 1)
    }

    func testFlushRunsPendingActionImmediatelyAndCancelsTimer() async throws {
        var count = 0
        let saver = DebouncedSaver(delay: .seconds(10)) { count += 1 }
        saver.schedule()
        saver.flush()
        XCTAssertEqual(count, 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(count, 1)
    }

    func testFlushWithoutPendingDoesNothing() {
        var count = 0
        let saver = DebouncedSaver(delay: .seconds(10)) { count += 1 }
        saver.flush()
        XCTAssertEqual(count, 0)
    }
}
