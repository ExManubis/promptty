import XCTest
@testable import GhosttyBridge

@MainActor
final class SecureInputOwnerTests: XCTestCase {
    private var enables = 0
    private var disables = 0
    private var succeeds = true

    private func owner(active: Bool = true) -> SecureInputOwner<Int> {
        enables = 0
        disables = 0
        succeeds = true
        return SecureInputOwner(
            appActive: active,
            enable: { [self] in if succeeds { enables += 1 }; return succeeds },
            disable: { [self] in if succeeds { disables += 1 }; return succeeds }
        )
    }

    func testRequestOnlyCountsWhileThePaneIsFocused() {
        let o = owner()
        o.setRequested(1, true)
        XCTAssertFalse(o.enabled)
        o.setFocused(1, true)
        XCTAssertTrue(o.enabled)
        o.setFocused(1, false)
        XCTAssertFalse(o.enabled)
        XCTAssertEqual([enables, disables], [1, 1])
    }

    func testRepeatedRequestsAreNotCountedTwice() {
        let o = owner()
        o.setFocused(1, true)
        o.setRequested(1, true)
        o.setRequested(1, true)
        o.global = true
        XCTAssertEqual(enables, 1)
        o.setRequested(1, false)
        XCTAssertTrue(o.enabled, "still forced")
        o.global = false
        XCTAssertEqual([enables, disables], [1, 1])
    }

    func testGlobalAloneEnablesAndDisables() {
        let o = owner()
        o.global = true
        XCTAssertTrue(o.enabled)
        o.global = false
        XCTAssertFalse(o.enabled)
        XCTAssertEqual([enables, disables], [1, 1])
    }

    func testNothingWhileTheAppIsNotActiveAndItComesBackOnActivation() {
        let o = owner(active: false)
        o.global = true
        XCTAssertFalse(o.enabled)
        XCTAssertEqual(enables, 0)
        o.setAppActive(true)
        XCTAssertTrue(o.enabled)
        o.setAppActive(false)
        XCTAssertFalse(o.enabled)
        o.setAppActive(false)
        XCTAssertEqual([enables, disables], [1, 1], "balanced, and no second disable")
    }

    func testRemovedPaneReleasesIt() {
        let o = owner()
        o.setFocused(1, true)
        o.setRequested(1, true)
        o.remove(1)
        XCTAssertFalse(o.enabled)
        XCTAssertFalse(o.isSecure(1))
        XCTAssertEqual([enables, disables], [1, 1])
    }

    func testAFailedCallIsRetriedAndLeavesTheStateUnchanged() {
        let o = owner()
        succeeds = false
        o.global = true
        XCTAssertFalse(o.enabled)
        succeeds = true
        o.setAppActive(true)
        XCTAssertTrue(o.enabled)
        XCTAssertEqual(enables, 1)
    }

    func testShutDownBalances() {
        let o = owner()
        o.global = true
        o.setFocused(1, true)
        o.setRequested(1, true)
        o.shutDown()
        XCTAssertFalse(o.enabled)
        XCTAssertEqual([enables, disables], [1, 1])
    }

    func testIndicatorFollowsForcedOrRequested() {
        let o = owner()
        XCTAssertFalse(o.isSecure(1))
        o.setRequested(1, true)
        XCTAssertTrue(o.isSecure(1))
        XCTAssertFalse(o.isSecure(2))
        o.global = true
        XCTAssertTrue(o.isSecure(2))
    }

    func testOnChangeFiresOnlyOnChanges() {
        let o = owner()
        var changes = 0
        o.onChange = { changes += 1 }
        o.setFocused(1, true)
        o.setRequested(1, true)
        o.setRequested(1, true)
        o.setRequested(1, false)
        XCTAssertEqual(changes, 2)
    }
}
