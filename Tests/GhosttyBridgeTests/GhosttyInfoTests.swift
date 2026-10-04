import XCTest
@testable import GhosttyBridge

final class GhosttyInfoTests: XCTestCase {
    func testVersionStringIsNonEmpty() {
        XCTAssertFalse(GhosttyInfo.version.isEmpty)
    }
}
