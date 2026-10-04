import XCTest
@testable import WorkspaceModel

@MainActor
final class WorkspaceTests: XCTestCase {
    func testDefaultLayoutIsSidebarAndToggles() {
        let ws = Workspace()
        XCTAssertEqual(ws.tabLayout, .sidebar)
        ws.toggleTabLayout()
        XCTAssertEqual(ws.tabLayout, .strip)
    }

    func testAddAndRemoveWindows() {
        let ws = Workspace()
        let a = ws.addWindow()
        let b = ws.addWindow(frame: WindowFrame(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(ws.windows.map(\.id), [a.id, b.id])
        XCTAssertEqual(b.frame, WindowFrame(x: 1, y: 2, width: 3, height: 4))
        ws.removeWindow(id: a.id)
        XCTAssertEqual(ws.windows.map(\.id), [b.id])
        XCTAssertNil(ws.window(id: a.id))
    }

    func testWindowContainingTab() {
        let ws = Workspace()
        let a = ws.addWindow()
        let b = ws.addWindow()
        let tab = b.addTab(title: "x", workingDirectory: "/")
        XCTAssertEqual(ws.window(containing: tab.id)?.id, b.id)
        XCTAssertNil(ws.window(containing: TabID()))
        _ = a
    }
}
