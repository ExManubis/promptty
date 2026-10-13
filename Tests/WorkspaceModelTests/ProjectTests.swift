import XCTest
@testable import WorkspaceModel

@MainActor
final class ProjectTests: XCTestCase {
    private func titles(_ w: WindowState) -> [String] { w.tabs.map(\.title) }

    private func id(_ title: String, in w: WindowState) -> TabID { w.tabs.first { $0.title == title }!.id }

    /// A window with tabs t0…t(n-1), in no project.
    private func workspace(tabCount: Int) -> (Workspace, WindowState) {
        let ws = Workspace()
        let w = ws.addWindow()
        for i in 0..<tabCount { _ = w.addTab(title: "t\(i)", workingDirectory: "/tmp/\(i)") }
        return (ws, w)
    }

    // MARK: Projects

    func testABlankNameIsUntitled() {
        let ws = Workspace()
        XCTAssertEqual(ws.addProject(name: "  ").name, "New Project")
        XCTAssertEqual(ws.addProject(name: " Web ").name, "Web")
    }

    func testAddingAtAnIndex() {
        let ws = Workspace()
        let a = ws.addProject(name: "a")
        let b = ws.addProject(name: "b", at: 0)
        let c = ws.addProject(name: "c", at: 99)
        XCTAssertEqual(ws.projects.map(\.id), [b.id, a.id, c.id])
    }

    // MARK: Tabs

    func testAProjectDoesNotMoveItsTabs() {
        let (ws, w) = workspace(tabCount: 4)
        let web = ws.addProject(name: "web")
        w.setProject(id("t3", in: w), web.id)
        w.setProject(id("t1", in: w), web.id)
        XCTAssertEqual(titles(w), ["t0", "t1", "t2", "t3"])
        XCTAssertEqual(w.tabs.map { w.project(of: $0) }, [nil, web.id, nil, web.id])
        w.setProject(id("t1", in: w), nil)
        XCTAssertEqual(titles(w), ["t0", "t1", "t2", "t3"])
        XCTAssertNil(w.tab(id: id("t1", in: w))?.projectID)
    }

    func testANewTabInAProjectGoesAfterTheSelectedTab() {
        let (ws, w) = workspace(tabCount: 3)
        let web = ws.addProject(name: "web")
        w.select(id: id("t0", in: w))
        let new = w.addTab(title: "n", workingDirectory: "/web", project: web.id)
        XCTAssertEqual(titles(w), ["t0", "n", "t1", "t2"])
        XCTAssertEqual(new.projectID, web.id)
        XCTAssertEqual(w.selectedTabID, new.id)
    }

    func testAPinnedTabCanBeInAProject() {
        let (ws, w) = workspace(tabCount: 2)
        let web = ws.addProject(name: "web")
        w.pin(id("t1", in: w), TabPin(directory: "/tmp/1", command: nil))
        w.setProject(id("t1", in: w), web.id)
        XCTAssertEqual(titles(w), ["t1", "t0"])
        XCTAssertEqual(w.project(of: w.tabs[0]), web.id)
    }

    func testRemovingAProjectKeepsItsTabsInNone() {
        let (ws, w) = workspace(tabCount: 3)
        let web = ws.addProject(name: "web")
        let api = ws.addProject(name: "api")
        w.setProject(id("t2", in: w), api.id)
        w.setProject(id("t1", in: w), web.id)
        ws.removeProject(id: web.id)
        XCTAssertEqual(titles(w), ["t0", "t1", "t2"])
        XCTAssertNil(w.tab(id: id("t1", in: w))?.projectID)
        XCTAssertEqual(w.tab(id: id("t2", in: w))?.projectID, api.id)
        XCTAssertEqual(ws.projects.map(\.id), [api.id])
    }

    func testMovingAProjectReordersOnlyTheProjects() {
        let (ws, w) = workspace(tabCount: 2)
        let web = ws.addProject(name: "web")
        let api = ws.addProject(name: "api")
        w.setProject(id("t0", in: w), web.id)
        w.setProject(id("t1", in: w), api.id)
        ws.moveProject(id: api.id, to: 0)
        XCTAssertEqual(ws.projects.map(\.id), [api.id, web.id])
        XCTAssertEqual(titles(w), ["t0", "t1"])
        ws.moveProject(id: api.id, to: 99)
        XCTAssertEqual(ws.projects.map(\.id), [web.id, api.id], "clamped to the end")
    }

    func testAWindowAddedLaterKnowsTheProjects() {
        let ws = Workspace()
        let web = ws.addProject(name: "web")
        let w = ws.addWindow()
        let tab = w.addTab(title: "w", workingDirectory: "/web", project: web.id)
        XCTAssertEqual(w.project(of: tab), web.id)
    }

    func testAPaneMovedIntoAnotherTabIsInThatTabsProject() {
        let (ws, w) = workspace(tabCount: 2)
        let web = ws.addProject(name: "web")
        w.setProject(id("t0", in: w), web.id)
        let target = w.tabs[0]
        let moving = w.tabs[1].focusedPaneID
        XCTAssertTrue(ws.movePane(moving, intoTab: target.id))
        XCTAssertEqual(ws.tab(containing: moving)?.1.projectID, web.id)
    }

    // MARK: Session

    func testSessionRoundTripKeepsProjectsAndMembership() throws {
        let ws = Workspace()
        let web = ws.addProject(name: "web", icon: PinIcon(symbol: "globe", color: .blue))
        let api = ws.addProject(name: "api", folded: true)
        let w = ws.addWindow()
        _ = w.addTab(title: "x", workingDirectory: "/tmp")
        _ = w.addTab(title: "a", workingDirectory: "/api", project: api.id)
        _ = w.addTab(title: "w", workingDirectory: "/web", project: web.id)
        w.pin(w.tabs.first { $0.title == "a" }!.id, TabPin(directory: "/api", command: "claude"))
        XCTAssertEqual(titles(w), ["a", "x", "w"])

        let data = try JSONEncoder().encode(ws.snapshot())
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(snap.projects, [
            ProjectSnapshot(id: web.id, name: "web", icon: PinIcon(symbol: "globe", color: .blue)),
            ProjectSnapshot(id: api.id, name: "api", folded: true),
        ])
        XCTAssertEqual(snap.windows[0].tabs.map(\.project), [api.id, nil, web.id])

        let restored = Workspace.restore(from: snap, directoryExists: { _ in true })
        XCTAssertEqual(restored.projects.map(\.id), [web.id, api.id])
        XCTAssertEqual(restored.projects.map(\.folded), [false, true])
        let rw = restored.windows[0]
        XCTAssertEqual(titles(rw), ["a", "x", "w"])
        XCTAssertEqual(rw.tabs.map(\.projectID), [api.id, nil, web.id])
        XCTAssertNotNil(rw.tabs[0].pin, "the pinned tab stays pinned, in its project")
    }

    func testASessionWithoutProjectsDecodes() throws {
        let json = """
        {"version": 1, "tabLayout": "sidebar", "windows": [{"tabs": [{"title": "a", "workingDirectory": "/a"}]}]}
        """
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.projects, [])
        XCTAssertNil(snap.windows[0].tabs[0].project)
    }

    func testATabNamingAnUnknownProjectRestoresInNone() {
        let snap = SessionSnapshot(
            version: SessionSnapshot.currentVersion, tabLayout: .sidebar,
            windows: [WindowSnapshot(frame: nil,
                                     tabs: [TabSnapshot(title: "a", customTitle: nil, workingDirectory: "/a", project: ProjectID())],
                                     selectedIndex: 0)]
        )
        let ws = Workspace.restore(from: snap, directoryExists: { _ in true })
        XCTAssertNil(ws.windows[0].tabs[0].projectID)
    }

    func testASessionFromWhenProjectsHadFoldersDecodes() throws {
        let id = ProjectID()
        let json = """
        {"version": 1, "tabLayout": "sidebar",
         "projects": [{"id": {"rawValue": "\(id.rawValue.uuidString)"}, "name": "old", "directory": "/src/old", "folded": false}],
         "windows": [{"tabs": [{"title": "a", "workingDirectory": "/a", "project": {"rawValue": "\(id.rawValue.uuidString)"}}]}]}
        """
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.projects, [ProjectSnapshot(id: id, name: "old")])
        XCTAssertEqual(snap.windows[0].tabs[0].project, id)
    }
}
