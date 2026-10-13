import XCTest
@testable import GhosttyBridge

final class ClipboardGrantsTests: XCTestCase {
    func testNothingIsAllowedAtFirst() {
        let g = ClipboardGrants()
        XCTAssertFalse(g.allows(.read))
        XCTAssertFalse(g.allows(.write))
    }

    func testGrantingOneKindLeavesTheOtherAsking() {
        var g = ClipboardGrants()
        g.grant(.write)
        XCTAssertTrue(g.allows(.write))
        XCTAssertFalse(g.allows(.read))
        g.grant(.read)
        XCTAssertTrue(g.allows(.read))
    }
}
