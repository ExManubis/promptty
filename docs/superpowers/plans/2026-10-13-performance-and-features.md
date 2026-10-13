# Performance and Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to
> implement this plan task-by-task.

**Goal:** Fix the performance problems found in the 2026-10-13 audit (idle wakeups, main-thread
I/O, resize storms, block-snapshot cost) and add the missing table-stakes and agent-workspace
features (links, search, secure input, progress, zoom, OSC 52, Claude Code hooks, worktrees, diff
review, undo close, command palette, block actions, Ctrl-R, bash/fish blocks).

**Spec:** none written; this plan is derived from the audit summarized to the user on 2026-10-13.
Each task states its own acceptance criteria.

**Tech stack:** Swift 6 (strict concurrency), AppKit + SwiftUI on macOS 26, libghostty built from
`Engine/` with PrompTTY's patches, XCTest, XcodeGen.

## Global Constraints

- Swift 6 language mode, strict concurrency complete. UI and model types are `@MainActor`.
- Only `GhosttyBridge` imports `GhosttyKit`. `WorkspaceModel` and `Preferences` import Foundation only.
- `~/.config/ghostty/*` is never read. libghostty config comes only from `terminal.conf`; its first line stays `keybind = clear`.
- Every PrompTTY *terminal-level* shortcut contains ⌘ and is defined in `ShortcutMap` (configurable in Settings › Keyboard). No Ctrl/Option combination without ⌘ is intercepted from the terminal. (Keys handled inside PrompTTY's own native input bar are not terminal shortcuts.)
- No SwiftUI `.keyboardShortcut` on chrome controls.
- Chrome text uses the system font; chrome icons are SF Symbols only.
- Engine changes go in `Engine/patches/*.patch`; rebuild with `./script/build-engine --force`.
- `./script/test` (swift test + app build) must pass before every commit. Add XCTest coverage for logic in the libraries (`WorkspaceModel`, `Preferences`, `CommandEditing`, `CommandBlocks`, `PaneActivity`, `GhosttyBridge` pure parts). UI behaviour is checked with the debug driver (`./script/drive`, commands in `Sources/PrompTTYApp/Debug/DebugDriver.swift`) where practical; extend the driver only if a task says so.
- Never write outside the repository during development or tests (in particular never touch `~/.claude`, `~/.zshrc`, `~/Library/Application Support/PrompTTY` of the real user; the driver takes its own data folder).
- Commit messages follow the repo style: `type(scope): lower-case sentence` (e.g. `perf(shell): …`, `feat(blocks): …`).
- Update README.md when a user-visible feature or shortcut is added.
- Match surrounding code: comment density, naming, idiom.

---

### Task 1: Bridge quick fixes — content scale, occlusion dedupe, tick coalescing, scrollbar fast path

**Files:** `Sources/GhosttyBridge/TerminalSurfaceView.swift`, `Sources/GhosttyBridge/GhosttyRuntime.swift`, `Sources/PrompTTYApp/WorkspaceCoordinator.swift`

1. `viewDidChangeBackingProperties` (TerminalSurfaceView.swift ~272): before `ghostty_surface_set_content_scale`, set the libghostty layer's `contentsScale = window.backingScaleFactor` inside a `CATransaction` with actions disabled (upstream Ghostty `SurfaceView_AppKit.swift` does this). Without it, a window moved Retina→1x renders 4× the pixels, 1x→Retina is blurry.
2. `updateOcclusion` (~356): remember the last visibility sent and return early if unchanged (same pattern as `sentSize`/`sentScale`). Each call currently wakes the renderer.
3. `GhosttyRuntime` wakeup callback (~176-184): coalesce — keep a lock-protected/atomic "tick pending" flag so at most one `DispatchQueue.main.async { tick() }` is queued at a time; clear the flag right before ticking.
4. `WorkspaceCoordinator.handle` `.scrollbar`/`.cellSize` (~643): stop calling `locate(view)` (which searches every window and tab) for these. Reach the pane's block overlay directly from the surface view (e.g. the surface view holds a weak reference / closure to its overlay refresh, set when the overlay is attached). Handle these cases before any `locate`.

**Acceptance:** builds, tests pass; no behaviour change other than the above. Unit-test the occlusion dedupe only if it can be done without a live surface; otherwise explain in the report.

### Task 2: One shared foreground poll instead of per-pane 4 Hz timers

**Files:** `Sources/PrompTTYApp/Shell/PaneShell.swift` (~422-428 `poll` timer), `Sources/PrompTTYApp/Chrome/ActivityTracker.swift` (~49 timer, ~70 screen reads, ~120 `isSeen`), `Sources/PaneActivity/PaneActivity.swift` (comment ~157)

1. Remove the per-pane 0.25 s idle `Timer` in `PaneShell`. Instead, `ActivityTracker`'s single timer (or one shared timer owned by the coordinator) calls each idle shell's `checkForeground()`.
2. The shared timer gets `tolerance` (~0.1 s). Panes the user can see (selected tab of a visible, non-occluded window) are checked every 0.25 s; unseen panes at most every 1 s. When no window is visible, only the 1 s cadence runs.
3. Agent screen hashing (`ActivityTracker` ~70) happens at the 0.5 s cadence only for seen panes and at 1–2 s for unseen panes. Fix the PaneActivity comment to match.
4. `isSeen` must not rebuild the whole watched-pane list per lookup: keep a set updated when visibility/selection changes, or compute once per tick.

**Acceptance:** a program started by `fg` or a shell hook while idle is still detected (bar hides) within ~0.3 s in a visible pane. Tests pass. Report the wakeup count before/after for 20 idle panes as reasoning (no need to measure).

### Task 3: Completion off the main thread, folder listed once per popup

**Files:** `Sources/CommandEditing/CompletionEngine.swift`, `Sources/PrompTTYApp/Shell/CompletionPopup.swift` (~17-31), `Sources/PrompTTYApp/Shell/CommandTextView.swift` (~195, 267, 338-364), `Sources/PrompTTYApp/Shell/PaneShell.swift` (`BranchCache`, `completionContext` ~226-234)

1. When the completion popup opens, list the folder once (off the main thread, like `FolderPicker.swift:20`) and keep the entries; `refilterCompletions()` filters the cached entries in memory per keystroke. Re-list only when the directory being completed changes (e.g. user types a `/`).
2. Git branch lookup (`gitBranches`, currently `PaneShell.run` with `DispatchSemaphore.wait` on the main thread, up to 1 s) runs asynchronously; the popup appears/updates when results arrive. Never block the main thread.
3. Move the branch cache into `PaneShell` so it survives across popups; clear it at each prompt.
4. Cache the merged command-name set that `completionContext()` builds (two sets of thousands of names) and invalidate when either input changes; `insertDroppedFiles` must not trigger the merge just to get the folder.
5. Keep `CompletionEngine` pure and synchronous over supplied data so it stays unit-testable; put the async fetching in the app layer. Add/adjust tests in `Tests/CommandEditingTests/CompletionEngineTests.swift` for filtering cached entries.

**Acceptance:** typing with the popup open in a 10k-entry folder does no disk I/O per keystroke; Tab after `git switch ` never freezes the UI. Tests pass.

### Task 4: Shared history store and cheaper ghost text

**Files:** `Sources/CommandEditing/ZshHistory.swift` (~74-93 `rebuild`), `Sources/CommandEditing/Autosuggester.swift`, `Sources/PrompTTYApp/Shell/PaneShell.swift` (~303, 343, 478-489), `Sources/PrompTTYApp/Shell/CommandTextView.swift` (~108-118, 376-384)

1. One reference-type history store per HISTFILE path, shared by all panes (registry keyed by path). File parsing and de-duplication happen once, off the main thread; panes observe the published result.
2. `add(command)` is O(1) amortized: put the command at the newest position and drop older duplicates lazily (index map or skip-on-read), no full `rebuild()` per Enter. `replaceFileEntries` when HISTFILE changed should also avoid a full rebuild where possible (append-only growth is the common case with `INC_APPEND_HISTORY`/`SHARE_HISTORY`); a full rebuild off-main is acceptable on truncation/rewrite.
3. Ghost-text: `updateSuggestion()` runs once per key (currently from both `didChangeText` and `setSelectedRanges`). If the new text extends the previous text and the previous text had no match, skip the scan. Remember the index of the last match and continue from there when the text is extended.
4. Behaviour (↑/↓ walking, prefix matching, de-dup order) unchanged; extend `HistoryTests.swift` / `AutosuggesterTests.swift` to cover O(1) add ordering and duplicate handling, plus the incremental suggestion path.

### Task 5: Command-block snapshots stop walking the whole scrollback

**Files:** `Engine/patches/0003-command-blocks.patch`, `Sources/GhosttyBridge/TerminalSurfaceView+Blocks.swift`, `Sources/CommandBlocks/CommandBlocks.swift`, `Sources/PrompTTYApp/Blocks/BlockOverlayView.swift` (~81-84 layout, ~101-130, ~239-292, ~334)

1. Engine patch: give `ghostty_surface_blocks` (the patch's `blocks.list`) a bound — list only blocks that intersect the viewport plus the one block above it (for the sticky header). Avoid the second full pass for `hasInput` and the repeated `pointFromPin(.screen)` page walks where possible. Keep a full-list variant for ⌘↑/⌘↓ navigation and copy (or make those operations walk incrementally from the selected block). Keep the C API change minimal and documented in the patch.
2. Rebuild the engine with `./script/build-engine --force` and confirm the app builds.
3. `BlockOverlayView`: skip the refresh triggered from `layout()` when bounds are unchanged; in `render()`, return early when snapshot, bounds, hover and selection are unchanged; set `buttons.appearance` only when dark/light actually changes; avoid allocating a 256-element array per `blockSnapshot()` (reuse a buffer).
4. When the viewport is at the bottom and no block is hovered/selected, throttle refreshes to ~20 Hz instead of 120 Hz.
5. Keep CommandBlocks tests passing; add tests for any new pure logic.

**Acceptance:** `yes | head -n 2000000` style streaming doesn't hold the terminal lock for a scrollback walk per frame; block selection, copy, sticky header and hover buttons still work (check with the debug driver).

### Task 6: No resize storms during sidebar animation and split dragging

**Files:** `Sources/PrompTTYApp/Chrome/WindowRootView.swift` (~51-80), `Sources/PrompTTYApp/Chrome/PaneHost.swift` (~100 `placeSurface`), `Sources/GhosttyBridge/TerminalSurfaceView.swift` (~294 `sizeDidChange`), `Sources/PrompTTYApp/Chrome/PaneTreeView.swift` (~119-125 `SplitDividerView.mouseDragged`), `Sources/PrompTTYApp/Chrome/PaneAnimation.swift`

1. Collapsing/expanding the sidebar must call `ghostty_surface_set_size` once per pane (final size), not per animation frame. Preferred approach: the same as pane moves — give the terminal its final frame once and animate visual motion with a transform/clip; alternative: a `TerminalSurfaceView.suspendResize` flag held for the animation's duration, sending the final size when it ends. Pick whichever fits the existing `PaneAnimation` machinery and explain.
2. Split divider drags: send terminal sizes at most every ~50 ms while dragging and always the final size on mouse-up; the card frame follows the pointer every event.
3. Verify with the debug driver's "pixel sizes sent" check (TerminalSurfaceView `#if DEBUG` hook) that a sidebar toggle produces one resize per pane.

### Task 7: The 120 Hz display link only runs while something is changing

**Files:** `Sources/PrompTTYApp/Chrome/TerminalWindowController.swift` (~710-760), `Sources/PrompTTYApp/WorkspaceCoordinator.swift` (`.render` currently ignored ~648)

1. With the ProMotion setting on, start the display link on key input and on terminal output/render for the window, and stop it after ~1 s with no input or render. Existing conditions (window key, app active, not occluded) still apply.
2. Route the `.render` action (or another cheap signal) to the window controller without a workspace search per event.

### Task 8: Fine-grained activity observation and agent list off the view body

**Files:** `Sources/PrompTTYApp/Chrome/ActivityTracker.swift` (~12, 117), `Sources/PrompTTYApp/Chrome/TabRow.swift` (~44, ~60), `Sources/PrompTTYApp/Chrome/AgentsSection.swift` (~22, ~126), `Sources/PrompTTYApp/WorkspaceCoordinator.swift` (~97-114 `agents()`, `repositories` cache)

1. Replace the single observed `activities` dictionary with per-pane `@Observable` boxes (only the box's visible projection is observed), so one pane's change re-renders only its row.
2. Precompute the agent list in the tracker/coordinator when membership/state changes; `AgentsSection.body` reads the precomputed list instead of walking all windows/tabs/panes.
3. `Repository.find` (checks `.git` in parent folders, reads HEAD) must not run inside a view body: resolve repositories off the main thread when a pane's folder changes and publish the result. Prune the `repositories` cache for folders no longer used.
4. `TabRow` `onGeometryChange(... .global)` writes `@State rowFrame` for every row each scroll frame: only track the frame while hovered (or derive it from the hover event).
5. Agent row "since" timer (`AgentsSection.swift` ~126): tick every second only while the label shows seconds (< 60 s), then every minute.

### Task 9: Blocking processes off the cooperative pool; shared PATH scan; one git status per cd

**Files:** `Sources/PrompTTYApp/Shell/PaneShell.swift` (~207, ~188, ~262-280 `listCommands`, ~356-359, ~466-476, ~496-534)

1. `PaneShell.run` (and callers using `Task.detached { Self.run(...) }` + `DispatchSemaphore.wait`) must not block Swift-concurrency pool threads: use `Process.terminationHandler` + `withCheckedContinuation` (with the same timeout semantics, terminating the process on timeout) or a dedicated dispatch queue.
2. Cache the PATH command set by PATH string across all panes (one scan per distinct PATH, off-main), so restoring N panes doesn't run N scans.
3. A `cd` triggers one `git status`, not two (`moveTo` ~207 and prompt-ready ~188). Add `--ignore-submodules=dirty` to the status call.
4. `reloadStateFileIfChanged` reads/parses off the main thread.
5. Keep generation-counter discard of stale results.

### Task 10: Open links with ⌘-click and show the link under the pointer

**Files:** `Sources/GhosttyBridge/GhosttyAction.swift`, `Sources/GhosttyBridge/GhosttyActionSink.swift`, `Sources/PrompTTYApp/WorkspaceCoordinator.swift`, `Sources/PrompTTYApp/Chrome/PaneCard.swift` (hover preview), `Sources/Preferences/TerminalConfigWriter.swift` (if `link-url`/`link` config is needed)

1. Decode `GHOSTTY_ACTION_OPEN_URL` and open with `NSWorkspace.shared.open` (http/https/mailto/file and other schemes NSWorkspace accepts; ignore empty/invalid). Make sure libghostty's URL detection is enabled and that ⌘-click (libghostty's default link modifier on macOS) triggers it; set the mouse pointer shape for links if not already handled.
2. Decode `GHOSTTY_ACTION_MOUSE_OVER_LINK` and show the URL in a small overlay at the bottom-left of the pane card while hovered (like a browser status bar); hide when nil.
3. Unit-test the action decoding in `GhosttyActionTests.swift`.

### Task 11: Secure keyboard entry

**Files:** `GhosttyAction.swift`, `WorkspaceCoordinator.swift`, `MainMenu.swift`, `Preferences/Settings.swift` (persist the manual toggle), a small helper in the app target

1. Decode `GHOSTTY_ACTION_SECURE_INPUT` (on/off/toggle). When a focused pane reports a password prompt, enable `EnableSecureEventInput()`; disable when it ends or the pane loses focus / app resigns active. Balance the calls exactly (secure input is a counted global state) — keep one owner object that tracks whether it has enabled it.
2. Add a "Secure Keyboard Entry" menu item (PrompTTY menu, checkmark) that forces it on while the app is active; persist it in settings.
3. Show a small lock SF Symbol in the pane card header or input area while secure input is active.

### Task 12: Progress reports (OSC 9;4)

**Files:** `GhosttyAction.swift`, `WorkspaceCoordinator.swift`, `ActivityTracker.swift` or the pane model, `TabRow.swift`, `AgentsSection.swift`/`ActivityViews.swift`

1. Decode `GHOSTTY_ACTION_PROGRESS_REPORT` (states: remove, set, error, indeterminate, pause; value 0–100).
2. Show a small circular progress indicator on the tab row (and the agent row if the pane is an agent): determinate ring for `set`, spinning for `indeterminate`, red for `error`, paused tint for `pause`, removed on `remove`. Clear it when the command finishes or after 15 s without an update (Ghostty's convention).
3. Unit-test decoding; keep the per-pane state where Task 8's per-pane observation applies (only that row redraws).

### Task 13: Pane zoom

**Files:** `ShortcutMap.swift` (new `zoomPane` action, default ⇧⌘↩), `MainMenu.swift`, `WorkspaceModel` (zoom state per tab), `PaneTreeView.swift`, `GhosttyAction.swift` (`TOGGLE_SPLIT_ZOOM` if libghostty emits it)

1. Zooming makes the focused pane fill the tab's pane area; other panes are hidden (and occluded) but kept alive. Toggle again, or focus-move/split/close, unzooms. Show an SF Symbol indicator on the zoomed card.
2. Zoom state is per tab and not persisted in the session snapshot (snapshot format unchanged).
3. Unit-test the model zoom state transitions in `WorkspaceModel` tests (create `Tests/WorkspaceModelTests` if absent, wired in Package.swift).
4. README Keys table gains the shortcut.

### Task 14: More command-block actions

**Files:** `Sources/PrompTTYApp/Blocks/*`, `Sources/CommandBlocks/CommandBlocks.swift`, `ShortcutMap.swift`, `MainMenu.swift`, `PaneShell.swift` (rerun into input bar)

1. **Rerun:** put the selected block's command into the input bar (not executed; user presses Return). Available from the block's hover buttons, the context menu, and a shortcut (default ⇧⌘R).
2. **Jump to failed:** select previous/next block whose exit code was non-zero (`CommandBlock.failed`), default ⌥⌘↑ / ⌥⌘↓.
3. **Copy as Markdown:** command and output as a fenced block: "```console\n$ <command>\n<output>\n```".
4. **Context menu** on a block header/area: Copy Command, Copy Output, Copy as Markdown, Rerun.
5. Unit-test the Markdown formatting and failed-block navigation logic in CommandBlocks tests.
6. Folding a block's output is out of scope (would need the engine to hide rows).

### Task 15: Ctrl-R fuzzy history search in the input bar

**Files:** `Sources/PrompTTYApp/Shell/CommandTextView.swift`, `PickerPanel.swift`, `Sources/CommandEditing/PickerFilter.swift`, history store from Task 4

1. With the input bar focused, Ctrl-R opens a picker (reuse `PickerPanel`/`PickerFilter`) over the shared history, newest first, fuzzy-filtered by the typed query, seeded with the bar's current text. Commands run in the current folder rank higher (use folder info if the history has it; otherwise skip that). Return inserts the command into the bar (not executed); Esc cancels. Ctrl-R again moves to the next match.
2. This key is handled only by the native input bar; while a program runs, Ctrl-R still goes to the terminal untouched.
3. Unit-test any new ranking logic.

### Task 16: Ask before clipboard access (OSC 52)

**Files:** `Sources/GhosttyBridge/GhosttyRuntime.swift` (clipboard read/confirm callbacks), `Sources/PrompTTYApp/Chrome/BannerView.swift`, `PaneCard.swift`, `Preferences/Settings.swift`

1. Replace silent deny/drop: when libghostty asks to confirm a clipboard read or write (`confirm_read_clipboard_cb` / unsafe paste), show a per-pane banner: "<program> wants to read/write the clipboard" with Allow, Deny, and "Always allow for this pane". Complete the request via `ghostty_surface_complete_clipboard_request` accordingly.
2. Settings › Terminal (or the most fitting section): "Clipboard access by programs": Ask (default) / Allow / Deny, written to `terminal.conf` as `clipboard-read`/`clipboard-write` values.
3. Unit-test the config writer lines.

### Task 17: Claude Code hooks integration (exact agent states)

**Files:** new `Sources/AgentHooks/` library (pure: message types, parsing, state reducer) with tests; app-side socket listener; `ZshIntegration.swift`/`PaneShell.swift` env (every pane, any shell); new executable target `promptty-hook` (SwiftPM + project.yml, embedded in the app bundle at `Contents/MacOS/promptty-hook` or `Contents/Resources/bin`); `ActivityTracker.swift`; `Notifications.swift`; Settings › Agents section.

1. Every pane's environment gets `PROMPTTY_PANE_ID` (stable UUID string of the pane) and `PROMPTTY_SOCKET` (Unix socket path under the app's data folder, e.g. `<AppPaths data>/hooks.sock`, mode 0600).
2. The app listens on the socket (off the main thread), accepting newline-delimited JSON messages `{pane, event, payload}`. Malformed messages are ignored; peers not owned by the same uid are rejected (`getpeereid`).
3. `promptty-hook <event>` reads the hook JSON from stdin (Claude Code passes it), adds `PROMPTTY_PANE_ID`, sends it to `PROMPTTY_SOCKET`, exits 0 quickly (≤200 ms timeout; never blocks or fails the agent; no output). Outside PrompTTY (env vars missing) it exits 0 silently.
4. Map events to agent state: `UserPromptSubmit`/`PreToolUse`/`PostToolUse` → working (record current tool name from `tool_name`); `Notification` → needs attention, with `permission` vs `idle` distinguished from the payload message (permission prompts vs "waiting for your input"); `Stop`/`SubagentStop` → your turn; `SessionStart`/`SessionEnd` → session id and transcript path known/cleared. Codex `notify` (JSON arg, `type: agent-turn-complete`) → your turn.
5. Hook-derived state takes precedence over screen hashing for that pane for as long as hook events arrive; fall back to screen hashing for panes without hooks (and if no event for that session for > 10 min while the process is gone).
6. UI: distinguish "needs permission" (distinct badge, e.g. `exclamationmark.shield`) from "your turn"; agent rows show the current tool name when working; notifications name which (permission vs done).
7. Settings › Agents: "Install Claude Code hooks…" button that, only when the user clicks it, shows what will change and then merges PrompTTY's hook entries into `~/.claude/settings.json` (create if missing, keep all existing content and existing hooks, idempotent, write a `.bak` first). Also a "Remove" button. Do NOT run it during development; test the merge function on fixture JSON in temp directories.
8. Unit tests: message parsing, event→state reducer, settings.json merge/unmerge (idempotent, preserves unrelated keys and other hooks).
9. README section describing the integration.

### Task 18: Find in scrollback (⌘F)

**Files:** `GhosttyAction.swift` (`START_SEARCH`, `END_SEARCH`, `SEARCH_TOTAL`, `SEARCH_SELECTED`), `GhosttyBridge` search API calls (binding actions `search:`, `navigate_search:next/previous`, `end_search` via `ghostty_surface_binding_action` — check the vendored Ghostty source under `.build/engine/libghostty-spm/vendor/ghostty` for the exact API), `ShortcutMap.swift` (find ⌘F, find next ⌘G, find previous ⇧⌘G), new `Sources/PrompTTYApp/Chrome/FindBar.swift`, `PaneCard.swift`, `MainMenu.swift` (Edit › Find submenu)

1. ⌘F opens a find bar at the top of the focused pane card (SwiftUI, system font, SF Symbols), prefilled with the selection if any. Typing searches live (debounced ~100 ms); shows "n of m"; Return/⌘G next, ⇧Return/⇧⌘G previous; Esc closes and returns focus to the terminal. Matches are highlighted by libghostty.
2. If libghostty in this version lacks a search API, implement search via the patch mechanism minimally or stop and report BLOCKED with findings — do not hand-roll scrollback scanning in Swift.
3. README Keys table updated.

### Task 19: New agent in a git worktree

**Files:** `Sources/PaneActivity/Repository.swift`, new pure helper in `CommandEditing` or `WorkspaceModel` for worktree naming/paths (tests), `MainMenu.swift`, tab/agent/project context menus (`TabRow.swift`, `GroupHeader.swift`, `AgentsSection.swift`), `WorkspaceCoordinator.swift`

1. "New Agent in Worktree…" (File menu and the project header "+" menu, when the selected tab's folder is in a git repository): a small sheet asks for a branch name (prefilled `agent/<short-random>`) and the command (default: the last agent command used, else `claude`). It runs `git worktree add -b <branch> <repo-parent>/<repo-name>.worktrees/<branch-slug>` off the main thread, then opens a new tab in that folder in the selected project and runs the command.
2. Remember on the tab that it owns a worktree (persist in the session snapshot in a backwards-compatible optional field; snapshot version unchanged). When such a tab closes, offer "Remove worktree" (only if the worktree has no uncommitted changes; otherwise say so and keep it).
3. Errors (not a repo, branch exists) show in the sheet.
4. Unit-test naming/path derivation and the snapshot field round-trip.

### Task 20: Diff review panel for an agent's changes

**Files:** new `Sources/PrompTTYApp/Chrome/ChangesPanel.swift`, pure diff parsing in a library (e.g. `CommandEditing/GitDiff.swift`) with tests, `AgentsSection.swift`/`TabRow.swift` context menus, `ShortcutMap.swift` (⌥⌘D "Show Changes")

1. "Show Changes" for a tab/agent whose folder is in a git repository opens a panel (sheet or trailing inspector in the window) listing changed files (`git status --porcelain=v2`) and, for the selected file, its unified diff (`git diff` against HEAD, including untracked files as additions) with added/removed line coloring in a monospaced font. Runs off the main thread; refresh button; refreshes automatically when that pane's agent reaches "your turn" (Task 17/screen-hash state) while the panel is open.
2. Read-only (no staging/committing).
3. Unit-test diff parsing (file headers, hunks, binary files, renames).

### Task 21: Reopen closed tab (⇧⌘T)

**Files:** `WorkspaceModel` (closed-tab stack), `WorkspaceCoordinator.swift`, `ShortcutMap.swift` (`reopenClosedTab`, ⇧⌘T), `MainMenu.swift`

1. When a tab (or a window's tabs) closes, push a snapshot of it (folder of each pane, split layout, pin, project membership, title) onto a per-app stack of at most 10, in memory only.
2. ⇧⌘T reopens the most recent closed tab in the current window at its old index if possible, starting shells in the saved folders; pinned tabs rerun their command. Processes cannot be revived — that's expected.
3. Unit-test the stack (bounded, LIFO) and snapshot→tab reconstruction in WorkspaceModel tests.

### Task 22: Command palette (⇧⌘P)

**Files:** new `Sources/PrompTTYApp/Chrome/CommandPalette.swift`, `ShortcutMap.swift` (`commandPalette`, ⇧⌘P), `MainMenu.swift`, reuse `PickerFilter`

1. ⇧⌘P opens a floating palette over the window: fuzzy search over (a) every `ShortcutMap` action and the menu actions added by this plan, showing their shortcut, (b) open tabs ("Go to tab: <title>"), (c) running agents ("Go to agent: <name>"), (d) projects ("New tab in <project>"). Return runs; Esc closes and returns focus to the terminal.
2. Actions run through the same code paths as the menu items (no duplicated logic).
3. Unit-test result ranking/filtering if new logic is introduced beyond `PickerFilter`.

### Task 23: Command blocks for bash and fish (OSC 133 without the input bar)

**Files:** `Sources/CommandEditing/ZshIntegration.swift` (pattern), new bash/fish integration scripts and installers alongside it, `Sources/PrompTTYApp/Shell/PaneShell.swift` (~12 shell detection), tests

1. For bash and fish login shells, load a PrompTTY integration script (bash: via `--rcfile`/`ENV` wrapper that sources the user's normal startup files first; fish: via `XDG_DATA_DIRS` vendor_conf.d or `--init-command`) that emits OSC 133 A/B/C/D marks (with exit code) and OSC 7 for the folder. The native input bar stays zsh-only; bash/fish keep the plain terminal prompt.
2. Command blocks, exit codes and durations then work for bash/fish panes via the existing engine marks.
3. Must not change behaviour when the user's own config already emits OSC 133 (don't double-mark: guard with an env flag).
4. Unit-test the generated scripts' content/launch arguments like `ZshIntegrationTests`.
5. README updated ("Other shells get command blocks but not the input bar").
