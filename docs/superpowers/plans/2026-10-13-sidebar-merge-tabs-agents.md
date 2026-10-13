# Sidebar: tabs and agents in one list — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sidebar's Agents section and flat tab list with one list of this window's tabs, grouped under projects, where a tab running an agent shows the agent's status on a second line; and remove the shimmer, spinner and breathing dot.

**Architecture:** The model (`WindowState`) gets back its ordering invariant (pinned, then each project's tabs, then the rest) from before `2f1a79c`. Pure functions in `PaneActivity.AgentListing` pick a tab's most urgent agent and build its status line; the coordinator publishes one summary per tab in `AgentList`; `TabRow` reads it. `AgentsSection`, `AgentGroups` and the looping animations other than the attention pulse are deleted.

**Tech Stack:** Swift 6.4, SwiftUI + AppKit (macOS), XCTest, SwiftPM (`swift test`), xcodegen + xcodebuild (`./script/test`), debug driver (`script/drive`).

**Spec:** `docs/superpowers/specs/2026-10-13-sidebar-merge-tabs-agents-design.md`

## Global Constraints

- Every sidebar tab row (`TabRow` `.full`) is 38 pt tall; strip pills (`.compact`) and tiles unchanged.
- Second line: `branch · state · tool · time · +N agents`; branch only when notable (not `main`/`master`); tool only while working or asking for permission; orange from `.attention` up.
- State labels: `.permission` "Needs permission", `.attention` "Your turn", `.working` "Working", anything else "Waiting".
- Count suffix: `+1 agent`, `+N agents` (others besides the shown one).
- Most urgent = highest `PaneActivity.Display`; ties → the tab's focused pane, then pane order.
- No shimmer, no spinning ring (indeterminate progress shows no ring), working dot is still; the attention pulse stays.
- `WindowState.tabs` order: pinned, then each project's tabs in `workspace.projects` order, then tabs in no project.
- Match the code's comment style: short doc comments in plain sentences, no TODOs.

## Review Focus

- A tab whose agent quits: the second line disappears and the row keeps 38 pt with its title centred — covered by the summary being nil when the tab has no agent (Task 2 test `testNoAgentsNoSummary`).
- A session saved by the current build (flat order, tabs of a project scattered): on restore the tabs regroup by project without losing any — Task 1 test `testRestoringAFlatSessionGroupsTheTabs`.
- Dragging a tab from another window onto a tab row: no index applies in this window; it must be ignored rather than misplaced — Task 4 guards `placeTab(_:inProject:at:)` with `index == nil || state.tab(id:) != nil`.
- A pinned tab given a project stays pinned and in the grid — Task 1 test `testAPinnedTabKeepsItsPlaceWhenGivenAProject`.
- Removing a project whose tabs are selected keeps the selection and puts its tabs first among the tabs in no project — Task 1 test `testRemovingAProjectKeepsItsTabsInNone`.

---

### Task 1: Model — tabs ordered by project

**Files:**
- Modify: `Sources/WorkspaceModel/WindowState.swift` (tabs doc, `projectOrder` didSet, `addTab`, `moveTab`, `setProject`, `unpin`, add `rank`, `bounds`, `regroup`)
- Modify: `Sources/WorkspaceModel/Workspace.swift` (`projects` doc, `moveProject`, `syncProjectOrder` calls `regroup()`)
- Modify: `Sources/WorkspaceModel/Project.swift`, `Sources/WorkspaceModel/Tab.swift` (doc comments)
- Test: `Tests/WorkspaceModelTests/ProjectTests.swift`

**Interfaces:**
- Produces: `WindowState.setProject(_ id: TabID, _ project: ProjectID?, at index: Int? = nil)`; `WindowState.regroup()` (internal); unchanged `addTab(…, project:)`, `moveTab(id:to:)`, `unpin(_:at:)` with grouped semantics.

- [ ] **Step 1: Restore the grouped-order tests.** Replace the "Tabs" tests in `ProjectTests.swift` with the versions from `git show 2f1a79c^:Tests/WorkspaceModelTests/ProjectTests.swift` (`testPuttingTabsInProjectsGroupsThemInProjectOrder`, `testANewTabGoesAfterTheSelectedTabInItsProject`, `testANewTabInAnotherProjectGoesFirstInIt`, `testANewTabNeverGoesAmongThePinnedTabs`, `testMovingATabStaysInItsProject`, `testAPinnedTabKeepsItsPlaceWhenGivenAProject`, `testUnpinningGoesFirstAmongItsProjectsTabs`, `testRemovingAProjectKeepsItsTabsInNone`, `testMovingAProjectMovesItsTabsInEveryWindow`, `testAWindowAddedLaterKnowsTheProjects`, `testGoingToTabsFollowsTheGroupedOrder`, and the session test's grouped expectations `["a", "w", "x"]`). Add:

```swift
func testRestoringAFlatSessionGroupsTheTabs() throws {
    let ws = Workspace()
    let web = ws.addProject(name: "web")
    let w = ws.addWindow()
    _ = w.addTab(title: "x", workingDirectory: "/tmp")
    _ = w.addTab(title: "w", workingDirectory: "/web", project: web.id)
    var snap = ws.snapshot()
    // As a build that kept tabs flat wrote it: the project's tab last.
    snap.windows[0].tabs.reverse()
    let restored = Workspace.restore(from: snap, directoryExists: { _ in true })
    XCTAssertEqual(titles(restored.windows[0]), ["w", "x"])
}
```

- [ ] **Step 2:** `swift test --filter ProjectTests` → expect failures (flat order).
- [ ] **Step 3: Restore the model.** Bring back from `2f1a79c^` the `tabs` doc comment, `projectOrder { didSet { if projectOrder != oldValue { regroup() } } }`, `addTab`'s group placement, `moveTab`'s `bounds(of: rank(of:))` clamp, `setProject(_:_:at:)`, `rank(of:)`, `bounds(of:)`, `regroup()`, and `unpin`'s group placement; in `Workspace.syncProjectOrder` call `w.regroup()` after setting the order, and the one-assignment comment in `moveProject`. Keep `paneIDs` (added later). If `snapshot.windows` / `tabs` are `let`, build the reversed snapshot in the test through its memberwise init instead.
- [ ] **Step 4:** `swift test --filter WorkspaceModelTests` → all pass.
- [ ] **Step 5: Commit** `feat(model): tabs are ordered by project again: pinned, each project's in order, then the rest`.

### Task 2: Agent summary and status line (pure)

**Files:**
- Modify: `Sources/PaneActivity/AgentListing.swift`
- Test: `Tests/PaneActivityTests/AgentListingTests.swift`

**Interfaces:**
- Produces:

```swift
extension AgentListing {
    /// The agent a tab's row shows: the most urgent; ties go to the focused pane, then pane order.
    public static func mostUrgent<ID: Equatable>(_ agents: [(id: ID, display: PaneActivity.Display)], focused: ID?) -> ID?
    /// "feature-x · Working · Bash · 20 s · +1 agent".
    public static func status(branch: String?, display: PaneActivity.Display, tool: String?, since: Date?,
                              others: Int, now: Date) -> String
}
```

- [ ] **Step 1: Tests.**

```swift
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
```

- [ ] **Step 2:** `swift test --filter AgentListingTests` → compile failure.
- [ ] **Step 3: Implement.**

```swift
public static func mostUrgent<ID: Equatable>(_ agents: [(id: ID, display: PaneActivity.Display)], focused: ID?) -> ID? {
    guard let top = agents.map(\.display).max() else { return nil }
    let candidates = agents.filter { $0.display == top }
    return (candidates.first { $0.id == focused } ?? candidates[0]).id
}

public static func status(branch: String?, display: PaneActivity.Display, tool: String?, since: Date?,
                          others: Int, now: Date) -> String {
    var parts: [String] = branch.map { [$0] } ?? []
    switch display {
    case .permission: parts.append("Needs permission")
    case .attention: parts.append("Your turn")
    case .working: parts.append("Working")
    default: parts.append("Waiting")
    }
    if let tool, display == .working || display == .permission { parts.append(tool) }
    if let since { parts.append(elapsed(now.timeIntervalSince(since))) }
    if others > 0 { parts.append(others == 1 ? "+1 agent" : "+\(others) agents") }
    return parts.joined(separator: " · ")
}
```

- [ ] **Step 4:** tests pass.
- [ ] **Step 5: Commit** `feat(agents): pick a tab's most urgent agent and word its status line`.

### Task 3: Per-tab summaries in `AgentList`

**Files:**
- Modify: `Sources/PrompTTYApp/Chrome/ChromeActions.swift` (`AgentList`, `AgentEntry`, add `TabAgentSummary`; remove `requestRenameTab`)
- Modify: `Sources/PrompTTYApp/WorkspaceCoordinator.swift` (`refreshAgents`, `agentEntries`)
- Modify: `Sources/PrompTTYApp/Chrome/TerminalWindowController.swift` (remove `requestRenameTab`)

**Interfaces:**
- Consumes: `AgentListing.mostUrgent`.
- Produces:

```swift
struct TabAgentSummary: Equatable {
    /// The most urgent agent in the tab.
    let entry: AgentEntry
    /// The tab's other agents.
    let others: Int
}
final class AgentList { var tabs: [TabID: TabAgentSummary] = [:]; func summary(for tab: TabID) -> TabAgentSummary? }
```

`AgentEntry` keeps `pane`, `program`, `display`, `repository`, `status` (drops `tab`, `title`, `projectID`); `AgentListing.title` and its test go if nothing else uses them.

- [ ] **Step 1:** Change `agentEntries()` to return `[TabID: TabAgentSummary]`: per tab, collect entries for agent panes, pick `AgentListing.mostUrgent(entries.map { ($0.pane, $0.display) }, focused: tab.focusedPaneID)`, store `TabAgentSummary(entry:, others: entries.count - 1)`. `refreshAgents` publishes `agentList.tabs` when it changed.
- [ ] **Step 2:** Remove `requestRenameTab` from the protocol and controller (only agent rows used it).
- [ ] **Step 3:** Build: `swift build` (the app target builds in Task 5's `./script/test`; AgentsSection still compiles against `entries` until Task 5, so delete `AgentsSection.swift` and its use in `SidebarView` in this task).
- [ ] **Step 4: Commit** `refactor(agents): one summary per tab, the most urgent agent and how many others`.

### Task 4: The tab row, two lines; less motion

**Files:**
- Modify: `Sources/PrompTTYApp/Chrome/ChromeMetrics.swift` (`tabRowHeight = 38`)
- Modify: `Sources/PrompTTYApp/Chrome/TabRow.swift` (row content, trailing ring/dot/close, drop delegate into a row's project, menu `placeTab(…, at: nil)`, accessibility label)
- Create: `Sources/PrompTTYApp/Chrome/AgentStatusLine.swift` (`AgentStatusLine` view + `SinceSchedule`)
- Modify: `Sources/PrompTTYApp/Chrome/ActivityViews.swift` (remove `WorkingShimmer`, `ShimmerBand`, `SpinningArc`, `.breathe`; indeterminate → no ring; `TabProgressRing` skips indeterminate)
- Modify: `Sources/PrompTTYApp/Chrome/PinIconPicker.swift` (`PinIconTile` without shimmer)

**Interfaces:**
- Consumes: `actions.agentList.summary(for:)`, `AgentListing.status`.
- Produces: `struct AgentStatusLine: View { let summary: TabAgentSummary }`.

- [ ] **Step 1:** `AgentStatusLine`: a `TimelineView(SinceSchedule(since:))` over `Text(AgentListing.status(branch: summary.entry.repository.notableBranch, display: activity.display, tool: activity.tool, since: activity.agentSince, others: summary.others, now: context.date))`, 10.5 pt, orange when `activity.display >= .attention`, `.id(activity.agentSince)`; `activity` read from `summary.entry.status.activity` so only this view observes the pane.
- [ ] **Step 2:** `rowContent` for `.full`: title (or rename field) and, when `actions.agentList.summary(for: tab.id)` exists, `AgentStatusLine` below it, in a `VStack(alignment: .leading, spacing: 0)`; height `ChromeMetrics.tabRowHeight` for `.full`. Trailing: `ZStack(alignment: .trailing)` of `HStack { TabProgressRing; ActivityIndicator(display:) }` hidden while hovering, and the close button shown while hovering.
- [ ] **Step 3:** Remove motion: delete `WorkingShimmer`, `ShimmerBand`, `SpinningArc`; `ProgressRing` draws nothing for `.indeterminate`; `TabProgressRing` takes the first non-indeterminate report; `LoopingDot` only pulses (no `Loop` enum), and `.working` falls to the still dot; `PinIconTile` drops its shimmer overlay and `display` parameter if nothing else needs it.
- [ ] **Step 4:** `./script/test` → OK.
- [ ] **Step 5: Commit** `feat(sidebar): tab rows show their agent's status on a second line; no shimmer, spinner or breathing dot`.

### Task 5: Project sections in the tab list

**Files:**
- Modify: `Sources/PrompTTYApp/Chrome/SidebarView.swift` (`ProjectSection`, ungrouped tabs, `NewTabRow` → a tab in no project)
- Modify: `Sources/PrompTTYApp/Chrome/GroupHeader.swift` (drop `Symbol.none`; `ProjectHeader` docs; folded dot)
- Modify: `Sources/PrompTTYApp/Chrome/TabStripView.swift` (divider between groups)
- Modify: `Sources/PrompTTYApp/Chrome/ChromeActions.swift`, `TerminalWindowController.swift`, `WorkspaceCoordinator.swift`, `Debug/DebugHooks.swift` (`placeTab(_:inProject:at:)`)
- Modify: `Sources/PaneActivity/Repository.swift`, `Tests/PaneActivityTests/RepositoryTests.swift` (remove `AgentGroups`)

**Interfaces:**
- Consumes: `WindowState.setProject(_:_:at:)`.
- Produces: `ChromeActions.placeTab(_ id: TabID, inProject: ProjectID?, at index: Int?)`.

- [ ] **Step 1:** Restore `ProjectSection` from `git show 2f1a79c^:Sources/PrompTTYApp/Chrome/SidebarView.swift`, passing `display:` = the most urgent `actions.activity(for:)` of its tabs' panes when folded. `ForEach(workspace.projects)` then the ungrouped tabs; `NewTabRow(action: { actions.newTab(inProject: nil) }, …)`.
- [ ] **Step 2:** `placeTab(_:inProject:at:)` end to end as before `2f1a79c` (coordinator unpins on a drop with an index, `setProject(id, project, at:)`, reloads; controller ignores an index for a tab of another window); `RowDropDelegate` drops onto a row via `placeTab(id, inProject: tab.projectID, at: destination)`; the header drop and menus pass `at: nil`; DebugHooks `projecttab` passes `at: nil`.
- [ ] **Step 3:** Strip divider where `state.project(of:)` changes after the pinned tabs.
- [ ] **Step 4:** Delete `AgentGroups` and its three tests; `GroupHeader.Symbol.none` goes; GroupHeader/ProjectHeader comments no longer mention the Agents section; `ProjectHeader` gets `noun: "tab"`.
- [ ] **Step 5:** `./script/test` → OK. Commit `feat(sidebar): the tab list is grouped by project; the Agents section is gone`.

### Task 6: Verify in the app; README

- [ ] **Step 1:** Launch with the debug driver (`script/drive`), make two projects, put tabs in them, a plain tab; `eval projects` shows the grouped order; screenshot the sidebar. Run an agent if one is installed to see the second line.
- [ ] **Step 2:** README "Tabs, projects and agents": projects group the tab list; a tab running an agent shows its state on a second line; no Agents section.
- [ ] **Step 3:** Update the spec's status to implemented. Commit `docs: the sidebar's one list of tabs, grouped by project, agents on their tabs' rows`.
