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

    /// A 0.25 s timer with 40% tolerance: each tick up to 0.1 s late, the next on time again.
    func testJitteredTicksKeepEveryJobOnItsTick() {
        var cadence = PollCadence<String>(slack: 0.25 * 0.45)
        let t0 = Date(timeIntervalSince1970: 1000)
        let lateness: [TimeInterval] = [0, 0.1, 0, 0.1, 0.1, 0, 0.05, 0.1, 0, 0, 0.1, 0, 0.1, 0.03, 0, 0]
        var halfSecond: [Int] = [], everySecond: [Int] = []
        for (tick, late) in lateness.enumerated() {
            let now = t0.addingTimeInterval(Double(tick) * 0.25 + late)
            if cadence.isDue("half", every: 0.5, at: now) { halfSecond.append(tick) }
            if cadence.isDue("second", every: 1, at: now) { everySecond.append(tick) }
        }
        XCTAssertEqual(halfSecond, Array(stride(from: 0, to: lateness.count, by: 2)))
        XCTAssertEqual(everySecond, Array(stride(from: 0, to: lateness.count, by: 4)))
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
