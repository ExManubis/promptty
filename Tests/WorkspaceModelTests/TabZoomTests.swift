import XCTest
@testable import WorkspaceModel

@MainActor
final class TabZoomTests: XCTestCase {
    private func splitTab() -> (Tab, PaneID, PaneID) {
        let tab = Tab(title: "t", workingDirectory: "/a")
        let first = tab.focusedPaneID
        let second = tab.split(first, direction: .right, workingDirectory: "/b").id
        return (tab, first, second)
    }

    func testToggleZoomsTheFocusedPaneAndBack() {
        let (tab, _, second) = splitTab()
        XCTAssertNil(tab.zoomedPaneID)
        tab.toggleZoom()
        XCTAssertEqual(tab.zoomedPaneID, second)
        tab.toggleZoom()
        XCTAssertNil(tab.zoomedPaneID)
    }

    func testSinglePaneTabDoesNotZoom() {
        let tab = Tab(title: "t", workingDirectory: "/a")
        tab.toggleZoom()
        XCTAssertNil(tab.zoomedPaneID)
    }

    func testMovingFocusUnzooms() {
        let (tab, first, second) = splitTab()
        tab.toggleZoom()
        XCTAssertTrue(tab.moveFocus(.left))
        XCTAssertEqual(tab.focusedPaneID, first)
        XCTAssertNil(tab.zoomedPaneID)
        XCTAssertNotEqual(first, second)
    }

    func testFailedFocusMoveKeepsZoom() {
        let (tab, _, second) = splitTab()
        tab.toggleZoom()
        XCTAssertFalse(tab.moveFocus(.right))
        XCTAssertEqual(tab.zoomedPaneID, second)
    }

    func testFocusingAnotherPaneUnzoomsButTheSameOneDoesNot() {
        let (tab, first, second) = splitTab()
        tab.toggleZoom()
        tab.focus(second)
        XCTAssertEqual(tab.zoomedPaneID, second)
        tab.focus(first)
        XCTAssertNil(tab.zoomedPaneID)
    }

    func testSplitUnzooms() {
        let (tab, _, second) = splitTab()
        tab.toggleZoom()
        _ = tab.split(second, direction: .down, workingDirectory: "/c")
        XCTAssertNil(tab.zoomedPaneID)
    }

    func testClosingAPaneUnzooms() {
        let (tab, first, second) = splitTab()
        tab.toggleZoom()
        XCTAssertTrue(tab.closePane(first))
        XCTAssertNil(tab.zoomedPaneID)
        XCTAssertEqual(tab.focusedPaneID, second)
    }

    func testResetUnzooms() {
        let (tab, _, _) = splitTab()
        tab.toggleZoom()
        tab.reset(workingDirectory: "/a", startupCommand: nil)
        XCTAssertNil(tab.zoomedPaneID)
    }
}
