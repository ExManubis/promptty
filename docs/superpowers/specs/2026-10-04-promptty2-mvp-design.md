# PrompTTY 2 MVP: native macOS terminal on libghostty

**Date:** 2026-10-04
**Status:** Design, approved in conversation

## Problem

PrompTTY today is a fork of Warp: 74 Rust crates, a custom GPU UI framework, and AGPL
code written for a hosted product. Carrying it is heavy, it never felt like a Mac app, and
the parts that matter (the agent workspace) are buried under parts that do not. The
rewrite starts from zero with a native stack and a terminal engine someone else maintains.

## Goal

A distinctive macOS agent workspace that hosts external CLI agents (Claude Code, Codex,
Gemini CLI and others) in terminal sessions, with a flat session list and native status
from agent hooks and PTY observation. Visually modeled on the Arc and Dia browsers: tinted
chrome with the terminal floating inside it as a rounded card.

This spec covers only the **MVP**: a simple terminal with tabs shown either vertically in a
sidebar or horizontally in a strip. Later steps are listed under "Backlog" and will each
get their own design.

## Decisions (locked)

- Swift 6, AppKit. No SwiftUI for the window chrome or the terminal host.
- libghostty is the terminal engine, consumed as the prebuilt `GhosttyKit` xcframework from
  the `libghostty-spm` package, pinned to an exact version. No Zig in the default build.
- One process. libghostty spawns and owns the shell PTY. Sessions die with the app; only
  the tab list and working directories are restored on relaunch.
- No Warp-style blocks. No custom input editor. The grid is a plain terminal.
- Read the user's `~/.config/ghostty/config`; never write to it.
- macOS 15 minimum.

## Out of scope for the MVP

Splits, tab groups or spaces, pinned tabs, a command bar, agent status badges, agent hooks,
session recording, a daemon, an MCP server, a browser pane, Sparkle updates, notarization
tooling.

## Architecture

Four layers, each a separate Swift target. Only `GhosttyBridge` imports `GhosttyKit`.

```
PrompTTYApp (app bundle)
  ├── Chrome          NSWindowController, sidebar / strip tab views, terminal container
  ├── WorkspaceModel  Workspace → Window → Tab, persistence (no AppKit)
  └── GhosttyBridge   ghostty_app_t owner, callbacks, TerminalSurfaceView, GhosttyAction
        └── GhosttyKit + GhosttyKitResources (SwiftPM binary + resources)
```

### WorkspaceModel

`@MainActor` observable classes.

- `Workspace`: ordered `[WindowState]`, `tabLayout: .sidebar | .strip`.
- `WindowState`: `id`, `frame`, ordered `[Tab]`, `selectedTabID`.
- `Tab`: `id`, `title` (from Ghostty `SET_TITLE`, user rename overrides), `workingDirectory`
  (from `PWD`), `surfaceID`.

Persistence: JSON at `~/Library/Application Support/PrompTTY/session.json`, written
debounced on change and on quit. Restore recreates windows and tabs with their working
directories; scrollback is not restored. `tabLayout` and window frames also live here.
App preferences that are not session state live in `UserDefaults`.

### GhosttyBridge

**`GhosttyRuntime`** (one per process, created at launch):

1. `ghostty_init(argc, argv)` once.
2. Set `GHOSTTY_RESOURCES_DIR` to the `GhosttyKitResources` bundle path **before** step 3 so
   terminfo and shell-integration resolve.
3. `ghostty_config_new`, `ghostty_config_load_default_files`,
   `ghostty_config_load_recursive_files`, `ghostty_config_finalize`.
4. `ghostty_app_new(&runtimeConfig, config)` with `userdata = Unmanaged.passUnretained(self)`.

`ghostty_runtime_config_s` callbacks are file-scope `@convention(c)` functions that recover
the runtime from `userdata`:

| Callback | Thread | Handling |
|---|---|---|
| `wakeup_cb` | any | `DispatchQueue.main.async { ghostty_app_tick(app) }` |
| `action_cb` | main (inside tick or `ghostty_surface_new`) | decode to `GhosttyAction`, dispatch, return handled |
| `read_clipboard_cb` | main | read `NSPasteboard`, `ghostty_surface_complete_clipboard_request` |
| `confirm_read_clipboard_cb` | main | approve immediately in the MVP |
| `write_clipboard_cb` | main | write `NSPasteboard.general` |
| `close_surface_cb` | main, may re-enter | enqueue a model event; never free the surface inline |

`action_cb` returns `false` for any action not implemented. Returning `true` for an
unimplemented action eats a user keybind.

**`GhosttyAction`** is a Swift enum decoded from `ghostty_action_s`. MVP cases:

- Tabs and windows: `newTab`, `closeTab`, `gotoTab(n | previous | next | last)`,
  `moveTab(offset)`, `newWindow`, `closeWindow`, `quit`.
- Surface state: `setTitle(String)`, `pwd(String)`, `initialSize(cols, rows)`,
  `cellSize(w, h)`, `mouseShape`, `mouseVisibility`, `render`.
- Config: `configChange(ghostty_config_t)`, `reloadConfig(soft: Bool)`, `openConfig`,
  `colorChange(kind, rgb)`.
- Process: `showChildExited(exitCode, runtimeMs)`, `desktopNotification(title, body)`.
- `unhandled` for everything else (returns false).

Every C string is copied into a Swift `String` before the callback returns.

**`TerminalSurfaceView: NSView, NSTextInputClient`**

- `wantsLayer = true`; `makeBackingLayer` returns a `CAMetalLayer` with
  `pixelFormat = .bgra8Unorm`, `isOpaque = false`, `displaySyncEnabled = true`.
- Creates the surface on first `viewDidMoveToWindow` via `ghostty_surface_new` with
  `ghostty_surface_config_s { nsview, scale_factor, working_directory, context }`.
  `command` is left unset so Ghostty launches the user's configured or login shell.
- Size: `ghostty_surface_set_size` in backing pixels from `setFrameSize`;
  `ghostty_surface_set_content_scale` from `viewDidChangeBackingProperties`.
- Focus: `ghostty_surface_set_focus` from `becomeFirstResponder`/`resignFirstResponder`
  and window key/main notifications. Occlusion: `ghostty_surface_set_occlusion` from
  `NSWindow.didChangeOcclusionStateNotification` and tab visibility, so hidden tabs stop
  rendering.
- Keyboard: `keyDown`/`keyUp`/`flagsChanged` → `ghostty_input_key_s` → `ghostty_surface_key`.
  IME: `setMarkedText` → `ghostty_surface_preedit`; `insertText` → `ghostty_surface_text`;
  `firstRect(forCharacterRange:)` → `ghostty_surface_ime_point`.
- Mouse: `mouseDown/Up`, `rightMouseDown/Up`, `otherMouseDown/Up` →
  `ghostty_surface_mouse_button`; `mouseMoved/Dragged` → `ghostty_surface_mouse_pos`;
  `scrollWheel` → `ghostty_surface_mouse_scroll` with precise-scroll and momentum flags;
  `pressureChange` → `ghostty_surface_mouse_pressure`.
- Teardown: `ghostty_surface_free` exactly once, guarded by a flag, because both the
  tab-close path and `close_surface_cb` can arrive.
- Known timing: `initialSize` and `cellSize` fire synchronously inside `ghostty_surface_new`
  before the view has a window. The bridge buffers them and the container applies them after
  the view is installed.

**Concurrency.** The bridge is `@MainActor`. `wakeup_cb` only dispatches. `action_cb` uses
`MainActor.assumeIsolated`. `nonisolated(unsafe)` is confined to the C pointer bindings and
`deinit`.

### Chrome

- `TerminalWindowController` owns an `NSWindow` with `.fullSizeContentView`, transparent
  titlebar, hidden title, and real system traffic lights repositioned into the chrome.
- Root `ChromeView` paints the tint and hosts either `SidebarTabListView` (vertical) or
  `TopTabStripView` (horizontal) plus one `TerminalContainerView`. Switching layout removes
  one list view and installs the other; both bind to the same `WindowState`.
- `TerminalContainerView` insets the active `TerminalSurfaceView` and clips it to a rounded
  card with a layer `cornerRadius` and `masksToBounds`. Inactive tabs' surface views stay
  alive but hidden and occluded.
- **Tint** derives from the Ghostty theme background reported by `colorChange(.background)`:
  lightened for light themes, darkened for dark themes, with a fixed accent fallback before
  the first report.
- Tab rows show title and `~`-abbreviated cwd. Rename on double-click, close on hover,
  reorder by drag, in both modes.
- A non-modal banner strip above the terminal card shows config errors ("Open config"
  action) and surface failures. No blocking alerts.
- Child exit shows Ghostty's own exited message inside the surface; the tab gains a Close
  affordance.

### Commands

Menu bar: File (New Window ⌘N, New Tab ⌘T, Close Tab ⌘W, Close Window ⇧⌘W), View (Toggle
Tab Layout ⌃⌘S, Show/Hide Sidebar ⌘B, Previous/Next Tab ⇧⌘[ ⇧⌘]), Window, Help. All
routed through the responder chain to `TerminalWindowController`. Ghostty's own tab
keybinds arrive as `GhosttyAction` and hit the same methods, so both paths stay in sync.

## Project layout and build

```
promptty-2/
  Package.swift                 # GhosttyBridge, WorkspaceModel, tests
  project.yml                   # XcodeGen → PrompTTY.xcodeproj
  Sources/
    PrompTTYApp/                # AppDelegate, Chrome/, Commands/
    GhosttyBridge/
    WorkspaceModel/
  Tests/
    WorkspaceModelTests/
    GhosttyBridgeTests/
  script/
    bootstrap                   # brew install xcodegen; xcodegen generate
    run                         # xcodebuild + open
    test                        # swift test for libraries, xcodebuild test for app
  docs/superpowers/{specs,plans}/
```

`GhosttyKit` is pinned with `exact:` in `Package.swift`. A `script/update-ghostty` is a
documented later addition for building the xcframework locally from Ghostty main.

## Testing

- `WorkspaceModelTests`: tab ordering, select/close/reopen semantics, cwd inheritance for
  new tabs, session JSON round trip, layout toggle persistence.
- `GhosttyBridgeTests`: `GhosttyAction` decoding from hand-built `ghostty_action_s` values;
  callback dispatch through a fake `ActionSink`; the "return false when unhandled" rule.
- Manual acceptance for the MVP: launch; open three tabs; run `echo`, `vim`, and `yazi`;
  resize and change display scale; toggle layout; rename and reorder tabs; quit and relaunch
  to see tabs and cwds restored; confirm `~/.config/ghostty/config` fonts and colors apply.

## Error handling

| Failure | Behavior |
|---|---|
| Ghostty config parse error | banner with "Open config"; continue with defaults |
| `ghostty_surface_new` fails | close the tab, banner explains |
| Shell exits | Ghostty's exited message, tab shows Close |
| Session file unreadable | start with one tab in `$HOME`, keep the bad file as `.bak` |
| Resources dir missing | fatal at launch with a clear message; this is a packaging bug |

## Backlog (not designed yet, in rough order)

1. Splits inside a tab.
2. Agent awareness: Unix socket for Claude Code / Codex hooks, status badges, attention
   rings, `COMMAND_FINISHED`, `PROGRESS_REPORT`, notifications.
3. Flat session list across windows with live status.
4. Session recording and replay timeline (candidate differentiator).
5. Terminal-as-a-tool: MCP server and CLI, successor to `prompttyctrl`.
6. Local xcframework build script tracking Ghostty main.
7. Signing, notarization, Sparkle.
