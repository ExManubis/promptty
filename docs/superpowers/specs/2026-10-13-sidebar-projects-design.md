# PrompTTY sidebar projects — design

Date: 2026-10-13 · Status: approved with the proposals below; implemented (see "As built" at the end)

## Goal

Projects the user defines in the sidebar: a named group of tabs tied to a folder, like a folder
in Dia's or Arc's sidebar. The tab list shows tabs under their project, and the Agents section
groups agents by the same projects, so the two halves of the sidebar agree.

Today agents are grouped automatically by `Project.find` (`Sources/PaneActivity/Project.swift`):
the git repository an agent works in, or its folder outside git. That gets it wrong for a
monorepo the user thinks of as several projects, for several repositories the user thinks of as
one, and for work outside git, where every folder becomes its own "project". Tabs are not grouped
at all.

## Decisions

- **A project is a named group of tabs with a folder.** New tabs in it open in its folder. It is
  a user object; nothing creates one automatically.
- **An agent belongs to the project of the tab it runs in**, not to the folder it works in. The
  user placed the tab; an agent that `cd`s elsewhere does not jump groups.
- **Agents in tabs outside any project keep today's grouping** by git repository, after the
  projects. Someone who never makes a project sees no change.
- **Projects are workspace-wide; membership is per tab.** Every window shows every project; each
  window's tab list shows that window's tabs in them. A tab keeps its project when it moves to
  another window.
- **One fold state per project**, shared by the tab list and the Agents section, saved with the
  session.
- **Pinned tabs stay in the pinned grid.** A pinned tab can belong to a project (its agents group
  there), but it is not drawn inside the project.
- **The window's tab order stays the visual order.** ⌘1…⌘9, next and previous tab, and vim
  navigation keep working unchanged (see the model invariant below).

## 1. Model (`WorkspaceModel`)

**Naming.** The existing git-based `PaneActivity.Project` is really a repository. It is renamed
`Repository` (and `AgentGroups` keyed on it accordingly), so `Project` can be the user's object.
The app imports both modules, so keeping both names would be ambiguous in every chrome file.

```swift
public struct ProjectID: Hashable, Codable, Sendable { public let rawValue: UUID }

@Observable public final class Project {
    public let id: ProjectID
    public var name: String
    public var directory: String
    public var icon: PinIcon?        // the pinned tabs' SF Symbol on a colored tile; nil: a folder
    public var folded: Bool
}
```

- `Workspace` gains `projects: [Project]` (their sidebar order) with `addProject`,
  `removeProject`, `renameProject`, `moveProject(to:)`.
- `Tab` gains `projectID: ProjectID?`.
- **Invariant**, like `pinnedCount` today: each `WindowState.tabs` is ordered pinned tabs, then
  each project's tabs together in `workspace.projects` order, then tabs without a project. Every
  mutation keeps it: `addTab` inserts at the end of the selected tab's project (or of the
  ungrouped tabs), `moveTab` clamps within the tab's project like it clamps within pinned tabs
  today, and `setProject(_:for:)` moves the tab to the end of its new project. Because the array
  is the visual order, everything that walks tabs by index is unchanged.
- **Removing a project** keeps its tabs: they become ungrouped (and move to the ungrouped end).
  Nothing closes.
- **A pane moved into another tab** (`movePane(_:intoTab:)`) belongs to that tab's project; the
  project is a property of the tab, so this needs no code.

## 2. Session

`SessionSnapshot.currentVersion` goes from 1 to 2:

- `SessionSnapshot.projects: [ProjectSnapshot]` (id, name, directory, icon, folded), absent in
  version 1 files, decoded as empty.
- `TabSnapshot.project: UUID?`, absent in older files. An ID with no matching project (a hand
  edit) restores the tab ungrouped.
- A project's folder that no longer exists keeps the project (it is the user's object) but marks
  it missing: new tabs in it open in the fallback directory, and the header shows a warning
  symbol with the path in its tooltip.

## 3. Sidebar

Order: traffic-light band, pinned grid, Agents section, then the projects, then the ungrouped
tabs, then "+ New Tab".

**Project header** (24 pt, like the Agents section's): chevron, icon, name, the folded count, and,
on hover, a "+" that opens a tab in the project's folder. Click folds. When folded it shows its
tabs' most urgent activity dot, and the selected style when it holds the window's selected tab
(the same rule the Agents section now uses for the focused agent).

**Context menus.**
- Project header: New Tab in Project, Rename…, Change Icon…, Change Folder…, Remove Project
  (confirmation names the number of tabs that become ungrouped).
- Tab row: Move to Project ▸ (the projects, then New Project…, then None), above Pin Tab.
- Sidebar background: New Project….

**New Project…** asks for a name and a folder. Both are prefilled from the selected tab: the
folder is its git repository's root (`Repository.find`) or its folder, and the name is that
folder's name. The selected tab joins the new project.

**Drag and drop.** A tab dropped on a project's header or among its tabs joins it there; dropped
among the ungrouped tabs, it leaves its project. Project headers drag to reorder projects. The
existing tab drag payload is reused; project headers get a new `DragPayload.project`.

**New tabs.** ⌘T opens the tab in the selected tab's project, in the folder the "Open new tabs
in" setting chooses (the current pane's, or home). The header's "+" always uses the project's
folder. "+ New Tab" at the end of the list opens an ungrouped tab.

**Tab strip layout.** No headers: tabs keep the same order, with a thin separator between
projects and the project's name in each tab's tooltip. Folding does not apply in the strip.

## 4. Agents section

`AgentsSection` groups by the tab's project first:

1. Agents whose tab has a project, under that project's header, in sidebar order (not by
   urgency, so the list does not reorder under the pointer; the header's dot still shows its
   most urgent agent).
2. Then agents in ungrouped tabs, grouped by `Repository` exactly as today, by urgency then name.

`AgentEntry` gains `projectID: ProjectID?`; `WorkspaceCoordinator.agents()` fills it from the
tab. `AgentGroups.group` takes a group key (a project ID or a repository root) and a flag for
whether that key's groups sort by urgency or keep their given order, so its sorting stays a pure,
tested function in `PaneActivity`. Folding a project in either place folds it in both. The branch
shown under an agent is unchanged (it tells parallel agents apart within a project too).

The single-group rule stays: with one group in total and no projects defined, the list is flat.
With projects defined, headers always show, so a project's name is visible even with one agent.

## 5. Structure

- `WorkspaceModel`: `Project`, `ProjectID`, the invariant in `WindowState`, project methods on
  `Workspace`, session version 2.
- `PaneActivity`: `Project` renamed `Repository`; `AgentGroups` generalized as above.
- `PrompTTYApp/Chrome`: `ProjectHeader` moves out of `AgentsSection.swift` into its own file and
  serves both sections; `SidebarView` lays out projects; `TabRow` menus; `DragSupport` payload;
  `ChromeActions` gains the project actions.
- `DebugHooks`/`DebugDriver`: commands to create a project, move a tab into it and fold it, so
  the UI can be checked by `script/drive`.

## Testing

- `WorkspaceModelTests`: the ordering invariant under add, close, move, pin, unpin, set project,
  remove project and moving a tab between windows; goto-tab and next/previous across projects;
  session round trip; decoding version 1 files; unknown project IDs; missing folders.
- `PaneActivityTests`: `AgentGroups` with mixed project and repository keys, ordering and
  stability; the `Repository` rename keeps the existing `Project.find` tests passing.
- Driver run: two projects and loose tabs in two windows; fold one; move a tab between projects by
  drag and by menu; an agent in each; relaunch and check everything is restored.

## Out of scope

- Nested projects.
- Projects that start their own tabs or commands at launch (pinned tabs already do this per tab).
- Per-project settings (theme, environment, shell).
- Automatically assigning tabs to projects by folder.

## Open questions (resolved: the proposals were taken)

1. **Ungrouped tabs: after the projects, or before them?** Proposed: after, without a header,
   like Arc's unpinned tabs. Before them keeps today's list on top for people with few projects.
2. **Every project in every window, or only those with tabs in it?** Proposed: every project,
   empty ones dimmed with their "+", so a project is one click away in any window. With many
   windows or projects that is noisy; the alternative is a per-window choice of projects.
3. **⌘T inheriting the project:** proposed yes. The alternative is that ⌘T always opens an
   ungrouped tab and only the header's "+" opens into a project.
4. **Should a new tab whose folder is inside a project's folder join it automatically?** Proposed
   no (out of scope above): membership stays explicit and predictable.

## As built (2026-10-13)

Where the implementation differs from the design above:

- **The session version stays 1.** Projects only add fields (`SessionSnapshot.projects`,
  `TabSnapshot.project`) that older builds ignore, so a session written now still opens in an
  older build, without its projects. Bumping the version would make older builds refuse the file.
- **New Project… asks only for the folder** (an open panel starting at the selected tab's
  repository); the project is named after the folder and can be renamed from its menu. Changing
  the folder of a project still named after its old folder renames it to the new one.
- **Projects are reordered with Move Up / Move Down** in the header's menu, not by dragging the
  header (a third drag payload type would also need registering in `Info.plist`).
- **A folded project header in the tab list shows no activity dot**, matching the rule that only
  the Agents section shows activity. It shows the selected style when it holds the selected tab.
- **A removed project's tabs join the tabs in no project first**, in their order, rather than last.
- **Tab rows in a project are indented 8 pt** under its header.
- The tab menu's "None" is **Remove from Project**.
- Debug driver: `eval project list|add|tab|newtab|fold|move|rename|remove` (see
  `DebugHooks.swift`).

Not yet verified: none of this has been compiled or run; it was written where no Swift toolchain
was available. `./script/test` and a driver run from the Testing section are the next step.
