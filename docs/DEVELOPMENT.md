# Developing PrompTTY

## Build

Requires an Apple silicon Mac with macOS 26, Xcode 26 or newer and its Metal toolchain, and Zig
0.15 (`brew install zig@0.15`). libghostty is built locally into `Engine/` from the Ghostty source
pinned by [libghostty-spm](https://github.com/sethdeckard/libghostty-spm), with PrompTTY's patches
in `Engine/patches/` applied on top; the first build takes a few minutes, later ones about one.

    ./script/bootstrap            # installs xcodegen if needed, builds the engine, resolves packages, generates the Xcode project
    ./script/run                  # builds Debug and launches the app
    ./script/test                 # library tests, then an app build
    ./script/build-engine --force # rebuilds the engine after changing a patch
    ./script/release              # a Developer ID signed, notarized disk image in dist/

`script/build-engine` uses `$ZIG` if set, else Homebrew's `zig@0.15`, else the `zig` on `PATH`,
and stops unless it is version 0.15.

## Layout

    Sources/WorkspaceModel   windows, tabs, panes, pins, projects and the split tree; session JSON (no AppKit)
    Sources/Preferences      settings.json, terminal.conf generation, shortcuts, theme catalog
    Sources/CommandEditing   the input bar's logic: zsh integration, history, completion, vi mode, git status
    Sources/CommandBlocks    command blocks: where each command and its output start and end
    Sources/PaneActivity     what runs in a pane: foreground process, known programs and agents, repositories
    Sources/GhosttyBridge    the only code that touches libghostty
    Sources/AgentHooks       agents' hook messages, the socket the app listens on, the hook state, Claude's settings merge
    Sources/promptty-hook    the helper agents' hooks run, bundled in the app; sends one line to the socket
    Sources/PrompTTYApp      AppKit windows and menus; SwiftUI chrome, input bar and Settings
    Engine/                  libghostty as a local SwiftPM package; patches/ holds PrompTTY's engine patches
    script/                  bootstrap, run, test, build-engine, release, drive
    packaging/               the disk image's background and layout

## Settings and config

Settings are stored in `~/Library/Application Support/PrompTTY/settings.json`. From them the app
writes `terminal.conf`, the only config libghostty reads. PrompTTY does not read
`~/.config/ghostty/config`. libghostty itself binds no keys (`keybind = clear`); PrompTTY claims
only shortcuts that contain ⌘, plus the vim-style navigation keys.

PrompTTY loads its zsh integration through `ZDOTDIR` and then the user's own files. Other shells
get a plain terminal, without the input bar.

## The promptty command

`Sources/promptty` (with `Sources/RemoteControl`) is bundled at `Contents/Resources/bin/promptty`,
not beside the app's own binary, which on a case-insensitive disk it would clash with. Every pane
starts with that folder first on its `PATH` and `PROMPTTY_CONTROL`, the control socket
(`control.sock` in the data folder, mode 0600, the user's own processes only; same fallbacks and
checks as the hook socket: a folder only the user owns, at most 64 connections sending a request at
once, each read without blocking a thread and hung up on after 10 s). `promptty` sends one JSON
`ControlRequest` line and reads one `ControlResponse` line, and talks only to a server run by the
same user (`getpeereid`); the app answers on the main thread (`WorkspaceCoordinator+Control.swift`).
A `wait` is answered when its command ends, when the next command starts in that pane without the
first reporting its end, or when the pane closes (status 1). Panes are found by full
id, then label, then id suffix (`PaneTarget`). Settings › Tabs › Command line turns answering off
(status 4).

## Restored output

With **Settings › Tabs › Keep each tab's output when quitting** on (and session restore on), the
app writes what each pane holds (its last 2000 lines, with colors, read with libghostty's VT
text format; only those rows are read) to `scrollback/<pane>.vt` in the data folder, at quit and
every two minutes (then only panes whose screen changed, written off the main thread); the session
file names each pane's file. A split tab is saved with its layout (`TabSnapshot.layout`:
the split tree, each pane's folder, label and file) and comes back split; a pinned tab comes back
as its pin, one pane. A restored zsh pane starts with
`PROMPTTY_RESTORE` set to its file: the integration's `.zshenv` prints it before anything else and
deletes it. Files no tab names any more are removed at the next write. Other shells start plain.

## Agent hooks

**Install Claude Code Hooks…** adds one hook per event (SessionStart, SessionEnd,
UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop, SubagentStop) to
`~/.claude/settings.json`, each running `'<PrompTTY.app>/Contents/MacOS/promptty-hook' <Event>`.
It keeps every other setting and hook (the file is rewritten with its keys sorted), copies the
file to `settings.json.bak` first (or, when that backup exists already, to a dated
`settings.json.bak-<date>`, so the original survives), and installing again changes nothing;
**Remove…** takes out only PrompTTY's entries (any command running a `…/promptty-hook`).

Every pane, whatever its shell, starts with `PROMPTTY_PANE_ID` (the pane's id) and
`PROMPTTY_SOCKET` (`hooks.sock` in the app's data folder, mode 0600; if that path is longer than
a Unix socket allows, `promptty-<hash of the folder>.sock` in the temporary folder instead).
`promptty-hook` reads the hook's JSON from standard input, keeps only the fields PrompTTY uses
(session id, transcript path, folder, tool name, notification text; never the prompt or a tool's
input), and sends them with the pane's id as one line to the socket. It prints nothing, always
exits 0, gives up after 200 ms and does nothing outside PrompTTY. The app accepts only processes of
the same user.

While a pane's hooks report, they decide its agent's state and its screen is not watched; without
hooks, or after ten minutes without one once the agent has gone, the screen is watched again
(still for three seconds: your turn). Return, Esc, y, n, a digit or ⌃C pressed at a permission
prompt counts as the answer. An interrupted turn (Esc, ⌃C, a prompt answered "no") runs no hook:
while the hooks say the agent works, a screen still for 3 s with no hook for 5 s ends the turn,
without a notification. If another PrompTTY already listens on the socket (two copies sharing a
data folder) it is left alone.

Limitations:

- Programs started from a pane inherit its variables, so an agent in a tmux session or an
  editor's terminal reports to the pane that started tmux or the editor. Those reports are
  ignored, as a pane shows an agent's state only while the agent itself is in front.
- The hooks name the app by its path: after moving PrompTTY.app, or when macOS runs it from a
  temporary copy (App Translocation, for an app opened where it was downloaded), they find nothing
  to run until they are installed again from Settings › Agents.

## Debug driver

Debug builds can be driven without Screen Recording or Accessibility access, which is how the UI
is checked in automated runs:

    ./script/drive start /tmp/ptty                 # launch with its own data folder
    ./script/drive run /tmp/ptty commands.txt      # actions, keys, typing, window snapshots
    ./script/drive stop /tmp/ptty

See `Sources/PrompTTYApp/Debug/DebugDriver.swift` for the command list.

A driven run keeps to its folder: settings and session in `<dir>/support`, Claude Code's settings
and ssh config in `<dir>/home`. Its panes still load your own `.zshrc`, but from the first prompt
on their history file is `<dir>/home/.zsh_history`, whatever `.zshrc` sets `HISTFILE` to: the
commands a run types never reach your real `~/.zsh_history`, and ⌃R shows only that folder's
history.
