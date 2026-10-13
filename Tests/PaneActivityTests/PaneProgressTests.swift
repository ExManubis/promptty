import XCTest
@testable import PaneActivity

final class PaneProgressTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    func testRemoveIsNil() {
        XCTAssertNil(PaneProgress(kind: nil, percent: 50, at: t0))
    }

    func testSetKeepsPercent() {
        let p = PaneProgress(kind: .set, percent: 40, at: t0)
        XCTAssertEqual(p?.kind, .set)
        XCTAssertEqual(p?.fraction, 0.4)
        XCTAssertEqual(PaneProgress(kind: .set, percent: nil, at: t0)?.fraction, 0)
    }

    func testPercentIsClamped() {
        XCTAssertEqual(PaneProgress(kind: .set, percent: 250, at: t0)?.fraction, 1)
        XCTAssertEqual(PaneProgress(kind: .set, percent: -5, at: t0)?.fraction, 0)
    }

    func testIndeterminateHasNoFraction() {
        XCTAssertNil(PaneProgress(kind: .indeterminate, percent: 30, at: t0)?.fraction)
    }

    func testErrorAndPauseWithoutValueAreFull() {
        XCTAssertEqual(PaneProgress(kind: .error, percent: nil, at: t0)?.fraction, 1)
        XCTAssertEqual(PaneProgress(kind: .pause, percent: nil, at: t0)?.fraction, 1)
        XCTAssertEqual(PaneProgress(kind: .error, percent: 70, at: t0)?.fraction, 0.7)
        XCTAssertEqual(PaneProgress(kind: .pause, percent: 20, at: t0)?.fraction, 0.2)
    }

    func testStaleAfterFifteenSeconds() {
        let p = PaneProgress(kind: .set, percent: 10, at: t0)!
        XCTAssertFalse(p.isStale(at: t0.addingTimeInterval(14.9)))
        XCTAssertTrue(p.isStale(at: t0.addingTimeInterval(15)))
    }
}
