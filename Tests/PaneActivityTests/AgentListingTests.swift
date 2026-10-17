import PaneActivity
import XCTest

final class AgentListingTests: XCTestCase {
    func testAgo() {
        XCTAssertEqual(AgentListing.ago(-3), "now")
        XCTAssertEqual(AgentListing.ago(59), "now")
        XCTAssertEqual(AgentListing.ago(60), "1m")
        XCTAssertEqual(AgentListing.ago(3599), "59m")
        XCTAssertEqual(AgentListing.ago(3600 * 12 + 5), "12h")
        XCTAssertEqual(AgentListing.ago(86400 * 3), "3d")
    }

    func testActivityLine() {
        XCTAssertEqual(AgentListing.activity(display: .working, tool: "Bash"), "Working · Bash")
        XCTAssertEqual(AgentListing.activity(display: .working, tool: nil), "Working")
        XCTAssertEqual(AgentListing.activity(display: .permission, tool: "Edit"), "Needs permission · Edit")
        XCTAssertEqual(AgentListing.activity(display: .attention, tool: "Bash"), "Your turn")
        XCTAssertEqual(AgentListing.activity(display: .idle, tool: nil), "Done")
    }

    func testTheMostUrgentAgentShowsTiesToTheFocusedPaneThenOrder() {
        XCTAssertNil(AgentListing.mostUrgent([(id: Int, display: PaneActivity.Display)](), focused: nil))
        XCTAssertEqual(AgentListing.mostUrgent([(1, .working), (2, .permission), (3, .attention)], focused: 1), 2)
        XCTAssertEqual(AgentListing.mostUrgent([(1, .working), (2, .working)], focused: 2), 2)
        XCTAssertEqual(AgentListing.mostUrgent([(1, .working), (2, .working)], focused: 9), 1)
    }

    func testTheOtherAgentsCount() {
        XCTAssertNil(AgentListing.others(0))
        XCTAssertEqual(AgentListing.others(1), "+1 agent")
        XCTAssertEqual(AgentListing.others(3), "+3 agents")
    }
}

final class RepositoryCacheTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private let app = Repository(root: "/src/app", branch: "main")

    func testANewFolderIsLookedUpOnce() {
        var cache = RepositoryCache()
        XCTAssertNil(cache.repository(for: "/src/app/Sources"))
        XCTAssertEqual(cache.due(["/src/app/Sources"], at: t0), ["/src/app/Sources"])
        // Pending: not asked again while the lookup runs.
        XCTAssertEqual(cache.due(["/src/app/Sources"], at: t0.addingTimeInterval(1)), [])
        XCTAssertTrue(cache.resolved("/src/app/Sources", app, at: t0.addingTimeInterval(1)))
        XCTAssertEqual(cache.repository(for: "/src/app/Sources"), app)
        XCTAssertEqual(cache.due(["/src/app/Sources"], at: t0.addingTimeInterval(2)), [])
    }

    /// An agent may switch branches: a folder is looked up again after a while, and an unchanged
    /// answer says so.
    func testAFolderIsLookedUpAgainAfterAWhile() {
        var cache = RepositoryCache(refreshAfter: 5)
        _ = cache.due(["/src/app"], at: t0)
        cache.resolved("/src/app", app, at: t0)
        XCTAssertEqual(cache.due(["/src/app"], at: t0.addingTimeInterval(4)), [])
        XCTAssertEqual(cache.due(["/src/app"], at: t0.addingTimeInterval(5)), ["/src/app"])
        XCTAssertFalse(cache.resolved("/src/app", app, at: t0.addingTimeInterval(5)))
        _ = cache.due(["/src/app"], at: t0.addingTimeInterval(10))
        XCTAssertTrue(cache.resolved("/src/app", Repository(root: "/src/app", branch: "fix"), at: t0.addingTimeInterval(10)))
        XCTAssertEqual(cache.repository(for: "/src/app")?.branch, "fix")
    }

    func testFoldersNoLongerUsedAreForgotten() {
        var cache = RepositoryCache()
        _ = cache.due(["/src/app", "/tmp"], at: t0)
        cache.resolved("/src/app", app, at: t0)
        XCTAssertEqual(cache.due(["/tmp"], at: t0), [])
        XCTAssertNil(cache.repository(for: "/src/app"))
        // A late answer for a forgotten folder is dropped.
        _ = cache.due(["/src/app"], at: t0)
        _ = cache.due([], at: t0)
        XCTAssertFalse(cache.resolved("/src/app", app, at: t0))
        XCTAssertNil(cache.repository(for: "/src/app"))
    }

    func testALookupThatNeverAnswersIsTriedAgain() {
        var cache = RepositoryCache(refreshAfter: 5)
        XCTAssertEqual(cache.due(["/src/app"], at: t0), ["/src/app"])
        XCTAssertEqual(cache.due(["/src/app"], at: t0.addingTimeInterval(6)), ["/src/app"])
    }
}
