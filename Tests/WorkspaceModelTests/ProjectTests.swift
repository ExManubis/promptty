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

    // MARK: Tab order

    func testPuttingTabsInProjectsGroupsThemInProjectOrder() {
        let (ws, w) = workspace(tabCount: 4)
        let web = ws.addProject(name: "web")
        let api = ws.addProject(name: "api")
        w.setProject(id("t3", in: w), api.id)
        XCTAssertEqual(titles(w), ["t3", "t0", "t1", "t2"])
        w.setProject(id("t2", in: w), web.id)
        XCTAssertEqual(titles(w), ["t2", "t3", "t0", "t1"], "web's tabs before api's, the others after")
        w.setProject(id("t0", in: w), web.id)
        XCTAssertEqual(titles(w), ["t2", "t0", "t3", "t1"], "after the project's other tabs")
        w.setProject(id("t0", in: w), web.id, at: 0)
        XCTAssertEqual(titles(w), ["t0", "t2", "t3", "t1"], "a drop at the top of the project")
        w.setProject(id("t0", in: w), nil)
        XCTAssertEqual(titles(w), ["t2", "t3", "t1", "t0"], "out of the project: after the others")
    }

    func testANewTabGoesAfterTheSelectedTabInItsProject() {
        let (ws, w) = workspace(tabCount: 2)
        let web = ws.addProject(name: "web")
        w.setProject(id("t0", in: w), web.id)
        w.setProject(id("t1", in: w), web.id)
        XCTAssertEqual(titles(w), ["t0", "t1"])
        w.select(id: id("t0", in: w))
        let new = w.addTab(title: "n", workingDirectory: "/web", project: web.id)
        XCTAssertEqual(titles(w), ["t0", "n", "t1"])
        XCTAssertEqual(w.selectedTabID, new.id)
        XCTAssertEqual(new.projectID, web.id)
    }

    func testANewTabInAnotherProjectGoesFirstInIt() {
        let (ws, w) = workspace(tabCount: 3)
        let web = ws.addProject(name: "web")
        let api = ws.addProject(name: "api")
        w.setProject(id("t0", in: w), web.id)
        w.setProject(id("t1", in: w), api.id)
        XCTAssertEqual(titles(w), ["t0", "t1", "t2"])
        w.select(id: id("t0", in: w))
        _ = w.addTab(title: "a", workingDirectory: "/api", project: api.id)
        XCTAssertEqual(titles(w), ["t0", "a", "t1", "t2"])
        w.select(id: id("t0", in: w))
        _ = w.addTab(title: "n", workingDirectory: "/tmp")
        XCTAssertEqual(titles(w), ["t0", "a", "t1", "n", "t2"], "first among the tabs in no project")
    }

    func testANewTabNeverGoesAmongThePinnedTabs() {
        let (ws, w) = workspace(tabCount: 2)
        let web = ws.addProject(name: "web")
        w.pin(id("t0", in: w), TabPin(directory: "/tmp/0", command: nil))
        w.select(id: id("t0", in: w))
        _ = w.addTab(title: "n", workingDirectory: "/web", project: web.id)
        XCTAssertEqual(titles(w), ["t0", "n", "t1"])
    }

    func testMovingATabStaysInItsProject() {
        let (ws, w) = workspace(tabCount: 4)
        let web = ws.addProject(name: "web")
        w.setProject(id("t0", in: w), web.id)
        w.setProject(id("t1", in: w), web.id)
        XCTAssertEqual(titles(w), ["t0", "t1", "t2", "t3"])
        w.moveTab(id: id("t0", in: w), to: 3)
        XCTAssertEqual(titles(w), ["t1", "t0", "t2", "t3"], "clamped to the end of web")
        w.moveTab(id: id("t3", in: w), to: 0)
        XCTAssertEqual(titles(w), ["t1", "t0", "t3", "t2"], "clamped to the start of the others")
    }

    func testAPinnedTabKeepsItsPlaceWhenGivenAProject() {
        let (ws, w) = workspace(tabCount: 3)
        let web = ws.addProject(name: "web")
        w.pin(id("t2", in: w), TabPin(directory: "/tmp/2", command: nil))
        XCTAssertEqual(titles(w), ["t2", "t0", "t1"])
        w.setProject(id("t2", in: w), web.id)
        XCTAssertEqual(titles(w), ["t2", "t0", "t1"])
        XCTAssertEqual(w.tabs[0].projectID, web.id)
    }

    func testUnpinningGoesFirstAmongItsProjectsTabs() {
        let (ws, w) = workspace(tabCount: 3)
        let web = ws.addProject(name: "web")
        w.setProject(id("t0", in: w), web.id)
        w.setProject(id("t1", in: w), web.id)
        w.pin(id("t1", in: w), TabPin(directory: "/tmp/1", command: nil))
        XCTAssertEqual(titles(w), ["t1", "t0", "t2"])
        w.unpin(id("t1", in: w))
        XCTAssertEqual(titles(w), ["t1", "t0", "t2"])
        XCTAssertEqual(w.pinnedCount, 0)
        w.pin(id("t0", in: w), TabPin(directory: "/tmp/0", command: nil))
        XCTAssertEqual(titles(w), ["t0", "t1", "t2"])
        w.unpin(id("t0", in: w), at: 99)
        XCTAssertEqual(titles(w), ["t1", "t0", "t2"], "clamped to the end of web")
    }

    func testRemovingAProjectKeepsItsTabsInNone() {
        let (ws, w) = workspace(tabCount: 3)
        let web = ws.addProject(name: "web")
        let api = ws.addProject(name: "api")
        w.setProject(id("t2", in: w), api.id)
        w.setProject(id("t1", in: w), web.id)
        XCTAssertEqual(titles(w), ["t1", "t2", "t0"])
        ws.removeProject(id: web.id)
        XCTAssertEqual(w.tabs.count, 3)
        XCTAssertNil(w.tab(id: id("t1", in: w))?.projectID)
        XCTAssertEqual(titles(w), ["t2", "t1", "t0"], "api's tab first, then the others")
        XCTAssertEqual(ws.projects.map(\.id), [api.id])
    }

    func testMovingAProjectMovesItsTabsInEveryWindow() {
        let ws = Workspace()
        let web = ws.addProject(name: "web")
        let api = ws.addProject(name: "api")
        let w1 = ws.addWindow()
        let w2 = ws.addWindow()
        for w in [w1, w2] {
            _ = w.addTab(title: "w", workingDirectory: "/web", project: web.id)
            _ = w.addTab(title: "a", workingDirectory: "/api", project: api.id)
            _ = w.addTab(title: "x", workingDirectory: "/tmp")
            XCTAssertEqual(titles(w), ["w", "a", "x"])
        }
        ws.moveProject(id: api.id, to: 0)
        XCTAssertEqual(ws.projects.map(\.id), [api.id, web.id])
        XCTAssertEqual(titles(w1), ["a", "w", "x"])
        XCTAssertEqual(titles(w2), ["a", "w", "x"])
    }

    func testAWindowAddedLaterKnowsTheProjects() {
        let ws = Workspace()
        let web = ws.addProject(name: "web")
        let w = ws.addWindow()
        _ = w.addTab(title: "x", workingDirectory: "/tmp")
        _ = w.addTab(title: "w", workingDirectory: "/web", project: web.id)
        XCTAssertEqual(titles(w), ["w", "x"])
        XCTAssertEqual(w.project(of: w.tabs[0]), web.id)
    }

    func testGoingToTabsFollowsTheGroupedOrder() {
        let (ws, w) = workspace(tabCount: 3)
        let web = ws.addProject(name: "web")
        w.setProject(id("t2", in: w), web.id)
        XCTAssertEqual(titles(w), ["t2", "t0", "t1"])
        w.gotoTab(.index(1))
        XCTAssertEqual(w.selectedTab?.title, "t2")
        w.gotoTab(.next)
        XCTAssertEqual(w.selectedTab?.title, "t0")
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
        XCTAssertEqual(titles(w), ["a", "w", "x"])

        let data = try JSONEncoder().encode(ws.snapshot())
        let snap = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(snap.projects, [
            ProjectSnapshot(id: web.id, name: "web", icon: PinIcon(symbol: "globe", color: .blue)),
            ProjectSnapshot(id: api.id, name: "api", folded: true),
        ])
        XCTAssertEqual(snap.windows[0].tabs.map(\.project), [api.id, web.id, nil])

        let restored = Workspace.restore(from: snap, directoryExists: { _ in true })
        XCTAssertEqual(restored.projects.map(\.id), [web.id, api.id])
        XCTAssertEqual(restored.projects.map(\.folded), [false, true])
        let rw = restored.windows[0]
        XCTAssertEqual(titles(rw), ["a", "w", "x"])
        XCTAssertEqual(rw.tabs.map(\.projectID), [api.id, web.id, nil])
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

    func testRestoringAFlatSessionGroupsTheTabs() {
        let ws = Workspace()
        let web = ws.addProject(name: "web")
        let w = ws.addWindow()
        _ = w.addTab(title: "x", workingDirectory: "/tmp")
        _ = w.addTab(title: "w", workingDirectory: "/web", project: web.id)
        var snap = ws.snapshot()
        // As a build that kept tabs flat wrote it: the project's tab last.
        snap.windows[0].tabs.sort { $0.title > $1.title }
        XCTAssertEqual(snap.windows[0].tabs.map(\.title), ["x", "w"])
        let restored = Workspace.restore(from: snap, directoryExists: { _ in true })
        XCTAssertEqual(titles(restored.windows[0]), ["w", "x"])
    }
}
