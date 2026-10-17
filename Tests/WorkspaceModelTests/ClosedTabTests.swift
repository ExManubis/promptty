import XCTest
@testable import WorkspaceModel

@MainActor
final class ClosedTabTests: XCTestCase {
    func testStackKeepsTheNewestTenAndPopsNewestFirst() {
        var stack = ClosedTabStack()
        let window = WindowID()
        for i in 0..<12 {
            stack.push(ClosedTab(customTitle: "\(i)", project: nil, window: window, index: 0, layout: .pane(workingDirectory: "/", focused: true)))
        }
        XCTAssertEqual(stack.count, ClosedTabStack.limit)
        XCTAssertEqual(stack.pop()?.customTitle, "11")
        XCTAssertEqual(stack.pop()?.customTitle, "10")
        while stack.pop() != nil {}
        XCTAssertTrue(stack.isEmpty)
    }

    func testReopenBringsBackSplitsFoldersFocusAndPlace() throws {
        let window = WindowState()
        window.addTab(title: "", workingDirectory: "/a")
        let tab = window.addTab(title: "", workingDirectory: "/b", customTitle: "server")
        window.addTab(title: "", workingDirectory: "/c")
        let right = tab.split(tab.focusedPaneID, direction: .right, workingDirectory: "/b/web")
        tab.split(right.id, direction: .down, workingDirectory: "/b/api")
        tab.focus(right.id)
        right.label = "web"
        let closed = try XCTUnwrap(window.closedTab(tab))
        XCTAssertEqual(closed.index, 1)
        window.closeTab(id: tab.id)

        let reopened = window.reopen(closed, projectExists: { _ in true }, directoryExists: { _ in true })
        XCTAssertEqual(window.index(of: reopened.id), 1)
        XCTAssertEqual(window.selectedTabID, reopened.id)
        XCTAssertEqual(reopened.customTitle, "server")
        XCTAssertEqual(reopened.orderedPanes.map(\.workingDirectory), ["/b", "/b/web", "/b/api"])
        XCTAssertEqual(reopened.focusedPane.workingDirectory, "/b/web")
        XCTAssertEqual(reopened.focusedPane.label, "web")
        XCTAssertEqual(reopened.closedLayout, closed.layout)
    }

    func testReopenFallsBackForMissingFoldersAndProjects() {
        let window = WindowState()
        let closed = ClosedTab(customTitle: nil, project: ProjectID(), window: window.id, index: 5,
                               layout: .split(axis: .horizontal, ratio: 0.3, first: .pane(workingDirectory: "/gone", focused: false),
                                              second: .pane(workingDirectory: "/here", focused: true)))
        let tab = window.reopen(closed, projectExists: { _ in false }, directoryExists: { $0 == "/here" }, fallbackDirectory: "/home")
        XCTAssertNil(tab.projectID)
        XCTAssertEqual(tab.orderedPanes.map(\.workingDirectory), ["/home", "/here"])
        XCTAssertEqual(tab.workingDirectory, "/here")
        XCTAssertEqual(window.tabs.count, 1)
    }
}

@MainActor
final class PaneLabelTests: XCTestCase {
    func testLabelsAreOneShortLineOrNothing() {
        XCTAssertEqual(Pane.label("  server  "), "server")
        XCTAssertEqual(Pane.label("a\nb"), "a b")
        XCTAssertNil(Pane.label("   "))
        XCTAssertEqual(Pane.label(String(repeating: "x", count: 50))?.count, 32)
    }

    func testTheFocusedPanesLabelSurvivesTheSession() throws {
        let ws = Workspace()
        let tab = ws.addWindow().addTab(title: "", workingDirectory: "/tmp")
        tab.focusedPane.label = "logs"
        let data = try JSONEncoder().encode(ws.snapshot())
        let restored = Workspace.restore(from: try JSONDecoder().decode(SessionSnapshot.self, from: data), directoryExists: { _ in true })
        XCTAssertEqual(restored.windows[0].tabs[0].focusedPane.label, "logs")
    }
}
