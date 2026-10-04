import XCTest
@testable import WorkspaceModel

final class TabLayoutTests: XCTestCase {
    func testToggleFlipsBetweenSidebarAndStrip() {
        XCTAssertEqual(TabLayout.sidebar.toggled, .strip)
        XCTAssertEqual(TabLayout.strip.toggled, .sidebar)
    }

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(TabLayout.sidebar.rawValue, "sidebar")
        XCTAssertEqual(TabLayout.strip.rawValue, "strip")
    }
}
