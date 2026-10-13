import XCTest
@testable import GhosttyBridge

final class ResizeThrottleTests: XCTestCase {
    func testFirstSizeGoesAtOnce() {
        XCTAssertEqual(ResizeThrottle().wait(at: 100), 0)
    }

    func testSizeSoonAfterAnotherWaitsForTheRestOfTheInterval() {
        var throttle = ResizeThrottle()
        throttle.noteSent(at: 100)
        XCTAssertEqual(throttle.wait(at: 100), ResizeThrottle.interval, accuracy: 1e-9)
        XCTAssertEqual(throttle.wait(at: 100.02), ResizeThrottle.interval - 0.02, accuracy: 1e-9)
    }

    func testSizeAfterTheIntervalGoesAtOnce() {
        var throttle = ResizeThrottle()
        throttle.noteSent(at: 100)
        XCTAssertEqual(throttle.wait(at: 100 + ResizeThrottle.interval), 0)
        XCTAssertEqual(throttle.wait(at: 101), 0)
    }

    func testEachSendRestartsTheInterval() {
        var throttle = ResizeThrottle()
        throttle.noteSent(at: 100)
        throttle.noteSent(at: 100.06)
        XCTAssertEqual(throttle.wait(at: 100.08), 0.03, accuracy: 1e-9)
    }

    /// A drag sending a new size every 16 ms reaches the terminal at most every interval.
    func testDragEventsAreSpacedOut() {
        var throttle = ResizeThrottle()
        var sent: [TimeInterval] = []
        for i in 0..<20 {
            let now = Double(i) * 0.016
            if throttle.wait(at: now) == 0 {
                throttle.noteSent(at: now)
                sent.append(now)
            }
        }
        XCTAssertEqual(sent.count, 5)
        for (a, b) in zip(sent, sent.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, ResizeThrottle.interval)
        }
    }
}
