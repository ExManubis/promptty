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

    func testAnAnswerAppliesOnlyToTheRequestItWasGivenFor() {
        XCTAssertEqual(ClipboardAnswer.resolve(.allow, answering: 3, pending: 3), .allow)
        XCTAssertEqual(ClipboardAnswer.resolve(.alwaysAllow, answering: 3, pending: 3), .alwaysAllow)
        XCTAssertEqual(ClipboardAnswer.resolve(.allow, answering: 3, pending: 4), .deny, "swapped request")
        XCTAssertEqual(ClipboardAnswer.resolve(.allow, answering: 3, pending: nil), .deny)
    }
}
