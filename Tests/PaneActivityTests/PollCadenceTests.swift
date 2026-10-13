import XCTest
@testable import PaneActivity

final class PollCadenceTests: XCTestCase {
    func testRunsFirstThenEveryInterval() {
        var cadence = PollCadence<String>()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(cadence.isDue("a", every: 1, at: t0))
        XCTAssertFalse(cadence.isDue("a", every: 1, at: t0.addingTimeInterval(0.25)))
        XCTAssertFalse(cadence.isDue("a", every: 1, at: t0.addingTimeInterval(0.75)))
        XCTAssertTrue(cadence.isDue("a", every: 1, at: t0.addingTimeInterval(1)))
    }

    func testEarlyTimerFireStillCounts() {
        var cadence = PollCadence<String>()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(cadence.isDue("a", every: 0.5, at: t0))
        XCTAssertTrue(cadence.isDue("a", every: 0.5, at: t0.addingTimeInterval(0.46)))
    }

    func testKeysAreIndependentAndForgettable() {
        var cadence = PollCadence<String>()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(cadence.isDue("a", every: 1, at: t0))
        XCTAssertTrue(cadence.isDue("b", every: 1, at: t0))
        cadence.forget("a")
        XCTAssertTrue(cadence.isDue("a", every: 1, at: t0.addingTimeInterval(0.1)))
        XCTAssertFalse(cadence.isDue("b", every: 1, at: t0.addingTimeInterval(0.1)))
    }
}
