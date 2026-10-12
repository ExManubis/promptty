import CoreGraphics
import XCTest
@testable import WorkspaceModel

final class PaneMotionTests: XCTestCase {
    private let a = PaneID(), b = PaneID(), c = PaneID()

    func testInterpolateIsLinearAndCanOvershoot() {
        let from = CGRect(x: 0, y: 0, width: 100, height: 100)
        let to = CGRect(x: 100, y: 50, width: 200, height: 100)
        XCTAssertEqual(PaneMotion.interpolate(from, to, 0.5), CGRect(x: 50, y: 25, width: 150, height: 100))
        XCTAssertEqual(PaneMotion.interpolate(from, to, 1.1).minX, 110, accuracy: 1e-9)
    }

    func testTransformIsIdentityWhenDrawnWhereLaidOut() {
        let r = CGRect(x: 10, y: 20, width: 300, height: 200)
        XCTAssertEqual(PaneMotion.transform(drawing: r, as: r), PaneMotion.Transform.identity)
    }

    func testTransformScalesAboutTheCenterAndOffsetsTheCenter() {
        let layout = CGRect(x: 500, y: 0, width: 500, height: 600)
        let visual = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let t = PaneMotion.transform(drawing: layout, as: visual)
        XCTAssertEqual(t.scaleX, 2)
        XCTAssertEqual(t.scaleY, 1)
        XCTAssertEqual(t.offsetX, -250) // centre 750 → 500
        XCTAssertEqual(t.offsetY, 0)
    }

    func testTransformOfAnEmptyLayoutIsIdentity() {
        let t = PaneMotion.transform(drawing: .zero, as: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(t, .identity)
    }

    func testFlightsStartWhereEachPaneIsDrawnNow() {
        let now: [PaneID: CGRect] = [a: CGRect(x: 0, y: 0, width: 1000, height: 600)]
        let next: [PaneID: CGRect] = [a: CGRect(x: 0, y: 0, width: 496, height: 600), b: CGRect(x: 504, y: 0, width: 496, height: 600)]
        let flights = PaneMotion.flights(from: now, to: next, popScale: 0.8)
        XCTAssertEqual(flights[a], PaneMotion.Flight(from: now[a]!, to: next[a]!, appearing: false))
        XCTAssertEqual(flights[b]?.appearing, true)
        let from = try! XCTUnwrap(flights[b]?.from)
        for (got, want) in [(from.minX, 553.6), (from.minY, 60), (from.width, 396.8), (from.height, 480)] {
            XCTAssertEqual(got, want, accuracy: 1e-9)
        }
    }

    func testFlightsIgnorePanesThatAreGone() {
        let now: [PaneID: CGRect] = [a: .zero, c: .zero]
        let flights = PaneMotion.flights(from: now, to: [a: .zero], popScale: 0.8)
        XCTAssertEqual(Set(flights.keys), [a])
    }

    func testFlightFramesAndOpacity() {
        let f = PaneMotion.Flight(from: .zero, to: CGRect(x: 0, y: 0, width: 10, height: 10), appearing: true)
        XCTAssertEqual(f.frame(at: 0), .zero)
        XCTAssertEqual(f.frame(at: 1), f.to)
        XCTAssertEqual(f.opacity(at: 0), 0)
        XCTAssertEqual(f.opacity(at: 1), 1)
        XCTAssertEqual(f.opacity(at: 1.05), 1, "overshoot never pushes opacity past 1")
        XCTAssertEqual(PaneMotion.Flight(from: .zero, to: .zero, appearing: false).opacity(at: 0), 1)
    }
}

final class TabSlideTests: XCTestCase {
    func testNextTabComesInFromAfterAndOldTabLeavesBefore() {
        XCTAssertEqual(PaneMotion.tabSlideFraction(selected: true, outgoing: false, direction: 1, progress: 0), 1)
        XCTAssertEqual(PaneMotion.tabSlideFraction(selected: false, outgoing: true, direction: 1, progress: 1), -1)
    }

    func testPreviousTabComesInFromBeforeAndOldTabLeavesAfter() {
        XCTAssertEqual(PaneMotion.tabSlideFraction(selected: true, outgoing: false, direction: -1, progress: 0), -1)
        XCTAssertEqual(PaneMotion.tabSlideFraction(selected: false, outgoing: true, direction: -1, progress: 1), 1)
    }

    func testAtRestTheSelectedTabSitsInPlace() {
        XCTAssertEqual(PaneMotion.tabSlideFraction(selected: true, outgoing: false, direction: -1, progress: 1), 0)
        XCTAssertEqual(PaneMotion.tabSlideFraction(selected: false, outgoing: false, direction: 1, progress: 0.5), 0)
    }
}
