import PaneActivity
import XCTest

final class AgentListingTests: XCTestCase {
    private let claude = ProgramCatalog.identify(executable: "/usr/local/bin/claude", arguments: ["claude"])!

    func testElapsed() {
        XCTAssertEqual(AgentListing.elapsed(-3), "0 s")
        XCTAssertEqual(AgentListing.elapsed(59.9), "59 s")
        XCTAssertEqual(AgentListing.elapsed(60), "1 min")
        XCTAssertEqual(AgentListing.elapsed(3_725), "1 h 2 min")
    }

    func testTheMostUrgentAgentShowsTiesToTheFocusedPaneThenOrder() {
        XCTAssertNil(AgentListing.mostUrgent([(id: Int, display: PaneActivity.Display)](), focused: nil))
        XCTAssertEqual(AgentListing.mostUrgent([(1, .working), (2, .permission), (3, .attention)], focused: 1), 2)
        XCTAssertEqual(AgentListing.mostUrgent([(1, .working), (2, .working)], focused: 2), 2)
        XCTAssertEqual(AgentListing.mostUrgent([(1, .working), (2, .working)], focused: 9), 1)
    }

    func testStatusLine() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(AgentListing.status(branch: "feature-x", display: .working, tool: "Bash", since: now - 20, others: 0, now: now),
                       "feature-x · Working · Bash · 20 s")
        XCTAssertEqual(AgentListing.status(branch: nil, display: .permission, tool: "Bash", since: now - 5, others: 1, now: now),
                       "Needs permission · Bash · 5 s · +1 agent")
        XCTAssertEqual(AgentListing.status(branch: nil, display: .attention, tool: "Bash", since: now - 120, others: 2, now: now),
                       "Your turn · 2 min · +2 agents")
        XCTAssertEqual(AgentListing.status(branch: nil, display: .idle, tool: nil, since: nil, others: 0, now: now), "Waiting")
    }

    /// Every second while the label shows seconds, then on each minute boundary.
    func testNextChangeTicksSecondsThenMinutes() {
        let since = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(AgentListing.nextChange(since: since, after: since), since.addingTimeInterval(1))
        XCTAssertEqual(AgentListing.nextChange(since: since, after: since.addingTimeInterval(12.4)), since.addingTimeInterval(13))
        XCTAssertEqual(AgentListing.nextChange(since: since, after: since.addingTimeInterval(58.5)), since.addingTimeInterval(59))
        XCTAssertEqual(AgentListing.nextChange(since: since, after: since.addingTimeInterval(59.2)), since.addingTimeInterval(60))
        XCTAssertEqual(AgentListing.nextChange(since: since, after: since.addingTimeInterval(60)), since.addingTimeInterval(120))
        XCTAssertEqual(AgentListing.nextChange(since: since, after: since.addingTimeInterval(130)), since.addingTimeInterval(180))
        // A clock behind `since` waits for the first second.
        XCTAssertEqual(AgentListing.nextChange(since: since, after: since.addingTimeInterval(-5)), since.addingTimeInterval(1))
        // Each tick's label differs from the one before it.
        var now = since
        var labels: [String] = []
        for _ in 0..<70 {
            labels.append(AgentListing.elapsed(now.timeIntervalSince(since)))
            now = AgentListing.nextChange(since: since, after: now)
        }
        XCTAssertEqual(Set(labels).count, labels.count)
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
