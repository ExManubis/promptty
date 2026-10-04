import XCTest
@testable import WorkspaceModel

@MainActor
final class WindowStateTests: XCTestCase {
    private func window(tabCount: Int) -> WindowState {
        let w = WindowState()
        for i in 0..<tabCount { _ = w.addTab(title: "t\(i)", workingDirectory: "/tmp/\(i)") }
        return w
    }

    func testNewWindowIsEmptyAndHasNoSelection() {
        let w = WindowState()
        XCTAssertTrue(w.isEmpty)
        XCTAssertNil(w.selectedTab)
    }

    func testAddTabInsertsAfterSelectionAndSelectsIt() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[0].id)
        let inserted = w.addTab(title: "new", workingDirectory: "/x")
        XCTAssertEqual(w.tabs.map(\.title), ["t0", "new", "t1", "t2"])
        XCTAssertEqual(w.selectedTabID, inserted.id)
    }

    func testCloseSelectedTabSelectsRightNeighborThenLeft() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[1].id)
        _ = w.closeTab(id: w.tabs[1].id)
        XCTAssertEqual(w.selectedTab?.title, "t2")
        _ = w.closeTab(id: w.tabs[1].id) // closes t2, nothing to the right
        XCTAssertEqual(w.selectedTab?.title, "t0")
    }

    func testCloseUnselectedTabKeepsSelection() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[2].id)
        _ = w.closeTab(id: w.tabs[0].id)
        XCTAssertEqual(w.selectedTab?.title, "t2")
    }

    func testCloseLastTabLeavesWindowEmpty() {
        let w = window(tabCount: 1)
        let closed = w.closeTab(id: w.tabs[0].id)
        XCTAssertNotNil(closed)
        XCTAssertTrue(w.isEmpty)
        XCTAssertNil(w.selectedTabID)
    }

    func testCloseUnknownTabReturnsNil() {
        let w = window(tabCount: 1)
        XCTAssertNil(w.closeTab(id: TabID()))
        XCTAssertEqual(w.tabs.count, 1)
    }

    func testGotoTabByOneBasedIndex() {
        let w = window(tabCount: 3)
        XCTAssertTrue(w.gotoTab(.index(1)))
        XCTAssertEqual(w.selectedTab?.title, "t0")
        XCTAssertTrue(w.gotoTab(.index(3)))
        XCTAssertEqual(w.selectedTab?.title, "t2")
    }

    func testGotoTabOutOfRangeReturnsFalseAndKeepsSelection() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[1].id)
        XCTAssertFalse(w.gotoTab(.index(0)))
        XCTAssertFalse(w.gotoTab(.index(4)))
        XCTAssertFalse(w.gotoTab(.index(-1)))
        XCTAssertEqual(w.selectedTab?.title, "t1")
    }

    func testGotoPreviousNextWrapAround() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[0].id)
        XCTAssertTrue(w.gotoTab(.previous))
        XCTAssertEqual(w.selectedTab?.title, "t2")
        XCTAssertTrue(w.gotoTab(.next))
        XCTAssertEqual(w.selectedTab?.title, "t0")
        XCTAssertTrue(w.gotoTab(.last))
        XCTAssertEqual(w.selectedTab?.title, "t2")
    }

    func testGotoOnSingleTabReturnsFalse() {
        let w = window(tabCount: 1)
        XCTAssertFalse(w.gotoTab(.next))
        XCTAssertFalse(w.gotoTab(.previous))
    }

    func testMoveSelectedTabClampsAtEnds() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[0].id)
        XCTAssertFalse(w.moveSelectedTab(by: -1))
        XCTAssertTrue(w.moveSelectedTab(by: 2))
        XCTAssertEqual(w.tabs.map(\.title), ["t1", "t2", "t0"])
        XCTAssertFalse(w.moveSelectedTab(by: 1))
        XCTAssertTrue(w.moveSelectedTab(by: -1))
        XCTAssertEqual(w.tabs.map(\.title), ["t1", "t0", "t2"])
        XCTAssertEqual(w.selectedTab?.title, "t0")
    }

    func testMoveSelectedTabByHugeAmountDoesNotOverflow() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[1].id)
        XCTAssertFalse(w.moveSelectedTab(by: Int.max))
        XCTAssertFalse(w.moveSelectedTab(by: Int.min))
        XCTAssertEqual(w.tabs.map(\.title), ["t0", "t1", "t2"])
    }

    func testMoveTabToIndexReorders() {
        let w = window(tabCount: 3)
        w.moveTab(id: w.tabs[2].id, to: 0)
        XCTAssertEqual(w.tabs.map(\.title), ["t2", "t0", "t1"])
    }
}
