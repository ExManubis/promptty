# PrompTTY sidebar: tabs and agents in one list — design

Date: 2026-10-13 · Status: implemented (the "+N agents" count is its own label, so it never truncates)

## Goal

The sidebar shows the same work twice: an agent pane appears as a row in the Agents section (every
window's agents, grouped by project or repository) and again as its tab's row in the tab list
below. Projects appear only in the Agents section. That is confusing.

Merge them: one list of this window's tabs, grouped under projects, where a tab running an agent
shows the agent's status on a second line. Also cut the sidebar's motion noise.

Supersedes, on the sidebar's layout, the "As built" notes of
`2026-10-13-sidebar-projects-design.md` that put projects only in the Agents section.

## Decisions

- **A row is a tab.** The list is this window's tabs. The Agents section goes away; agents in
  other windows are no longer listed in this sidebar (notifications and the Dock badge still
  cover them).
- **Every tab row is 38 pt tall**, the agent row's height today, so the list does not jump.
- **An agent tab has a second line** for its most urgent agent. **A plain tab has none**: its
  title alone, vertically centred (a tab's panes can be in several folders, so there is no one
  folder to show).
- **Several agents in a tab: the most urgent one shows**, with a count of the others.
- **Projects group the tab list** again, and the window's tab order follows them, so ⌘1…⌘9 and
  the strip agree with the sidebar. Tabs in no project are a flat list, not grouped by repository.
- **Less motion:** no shimmer on logos or tiles, no spinning progress ring, no breathing dot. The
  attention pulse stays.

## 1. The tab row (`TabRow`, `.full` style)

Layout, left to right: the panes' program logos (`ProgramStack`, focused pane in front), then

- an agent tab: the title on line 1 and the status on line 2;
- a plain tab: the title alone, vertically centred;

then the progress ring, then the activity dot. Both give way to the close button on hover. The
row is 38 pt (`ChromeMetrics` gains the height; the strip's `.compact` pills and the pinned
`.tile`s are unchanged).

**The second line** describes the tab's most urgent agent pane:
`branch · state · tool · time`, e.g. `feature-x · Working · Bash · 20 s`,
`Needs permission · Bash · 5 s`, `Your turn · 2 min`. The branch is the repository's notable
branch (as `AgentRow` shows it today) and is left out when there is none; the tool only while
working or asking for permission. With more agents in the tab, `· +1 agent` / `· +N agents` is
appended. The line is orange from `.attention` up, secondary otherwise. Durations tick only while
the row is shown: every second for the first minute, then every minute (today's `SinceSchedule`).

**Activity shows on tab rows** (the rule that only the Agents section shows activity goes with it):
`ActivityIndicator` on the trailing edge, for every tab, agent or not.

**Accessibility:** the row's label is title, "pinned" when pinned, the second line when present,
and the activity label.

## 2. Motion

- `WorkingShimmer` and `ShimmerBand` are removed: no band sweeps a working program's logo
  (`ProgramStack`) or a pinned tile's icon (`PinIconTile`).
- `SpinningArc` is removed. An indeterminate progress report shows no ring. A ring still shows a
  set percentage, an error (red) or a pause (yellow).
- The working dot is a still green dot: `LoopingDot`'s `.breathe` loop is removed. The attention
  pulse (`.pulse`) stays; reduce-motion keeps it still as today.

## 3. Projects and tab order

**The sidebar, top to bottom:** the traffic-lights band, the pinned tiles, each project's header
with its tabs below it (indented 8 pt) unless folded, the tabs in no project, "+ New Tab". The
"Agents" heading, the repository groups and "No agents yet" are gone.

**Model invariant (`WindowState`), restored from before `2f1a79c`:** `tabs` is ordered pinned tabs,
then each project's tabs together in `workspace.projects` order, then the tabs in no project.
Every mutation keeps it:

- `addTab(…, project:)` inserts after the selected tab when that tab is in the same group and not
  pinned, else at the start of the group (at its end when nothing is selected).
- `moveTab` clamps within the tab's group: pinned among pinned, a project's among that project's,
  the rest among the rest.
- `setProject(_:_:at:)` moves the tab into its new group, at `at` within it (a drop) or at its
  end. A pinned tab only changes `projectID`; it stays in the pinned grid.
- Changing `projectOrder` (reordering, adding or removing a project) regroups the tabs, keeping
  their order within each group. A removed project's tabs join the tabs in no project first.
- Going to tab N, the next and the previous tab, and vim navigation follow the array, unchanged.

**Project headers (`ProjectHeader`)** keep fold, drag to reorder, "+" (a new tab in the project),
the menu and the icon. The count reads "N tabs" (this window's). A **folded** header shows its
hidden tabs' most urgent activity dot, and the selected style when it holds the selected tab; an
unfolded header shows no dot. A project with no tabs in this window shows only its header.

**The strip** draws a thin divider where one project's tabs end and the next group's begin.

**Drag and drop:**

- A tab onto a project header: it joins the project, at the end.
- A tab onto a tab row: it moves to that row's place in that row's group, joining the row's
  project (or leaving its own, onto a row in no project). Onto a pinned tile, it is pinned there
  as today.
- A pane onto a tab row: the pane moves into the tab, as today.
- A project header onto a project header: reorder, as today.

## 4. Data

`WorkspaceCoordinator.agentEntries()` still builds the one list of every agent pane in every
window, and still drives the repository lookups (`RepositoryCache`). `AgentList` adds a per-tab
summary, built once per refresh rather than in a view's body:

```swift
struct TabAgentSummary: Equatable {
    /// The most urgent agent in the tab.
    let entry: AgentEntry
    /// Agents in the tab, this one included.
    let count: Int
}

extension AgentList {
    func summary(for tab: TabID) -> TabAgentSummary?
}
```

Most urgent: the highest `PaneActivity.Display`; ties go to the tab's focused pane, then to pane
order. The choice is a pure function in `PaneActivity` (beside `AgentListing`) so it is tested
without the app. `ChromeActions` exposes the summary to `TabRow`. The second line observes the
chosen entry's `PaneStatus`, as `AgentRow` does, so a ticking timer redraws only its row.

The status text (`AgentRow.state(of:now:)`) and `SinceSchedule` move out of `AgentsSection.swift`
into a shared place `TabRow` uses; the text assembly (branch, state, tool, time, count) becomes a
pure function in `AgentListing`.

## 5. Removed

- `Chrome/AgentsSection.swift`: `AgentsSection` and `AgentRow`, and with them the agent row's own
  menu (Show; Rename Tab… as a sheet). The tab menu already has Rename… and Move to Project ▸.
- `AgentGroups` (in `PaneActivity/Repository.swift`) and its tests: nothing else groups by
  repository. `Repository` and `RepositoryCache` stay, for the branch.
- `GroupHeader`, if nothing but the repository groups uses it once `AgentsSection` is gone.
- `WorkingShimmer`, `ShimmerBand`, `SpinningArc`, `LoopingDot`'s `.breathe`.
- Debug driver commands that read the Agents section are adapted to the tab rows.

## 6. Testing

- **`WorkspaceModelTests`:** the ordering invariant: `addTab` into a project and none, `moveTab`
  clamping per group, `setProject` with and without `at`, a pinned tab in a project staying
  pinned, reordering, adding and removing projects regrouping, and ⌘N targets following the
  visual order. Adapted from the `ProjectTests` removed in `2f1a79c`.
- **`PaneActivityTests`:** the summary choice (permission beats attention beats working beats
  waiting; ties to the focused pane, then pane order; the count) and the second line's text
  (branch present or not, tool only while working or asking, `+1 agent`, `+N agents`). Written
  test first.
- **The app:** `./script/test`, then a driver run (`script/drive`) with two projects, a split tab
  running two agents, and a plain tab: screenshots to check the 38 pt rows, the second line, a
  folded project's dot, the strip's dividers, ⌘1…⌘9 order, and that nothing shimmers or spins.
- **README:** the sidebar's description (Agents section, projects) updated.

## Follow-ups (not in this change)

- A plain tab's second line could show the focused pane's folder, with the other panes' folders in
  the tooltip.
- An indicator for agents needing attention in other windows, if notifications prove not enough.
