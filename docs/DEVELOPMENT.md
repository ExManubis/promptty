# Developing PrompTTY

## Build

Requires an Apple silicon Mac with macOS 26, Xcode 26 or newer and its Metal toolchain, and Zig
0.16 (`brew install zig@0.16`). libghostty is built locally into `Engine/` from the
[Ghostty](https://github.com/ghostty-org/ghostty) source pinned in `script/build-engine`, with
PrompTTY's patches in `Engine/patches/` applied on top; the first build takes a few minutes,
later ones about one.

    ./script/bootstrap            # installs xcodegen if needed, builds the engine, resolves packages, generates the Xcode project
    ./script/run                  # builds Debug and launches the app
    ./script/test                 # library tests, an iOS Simulator build of the portable modules, then an app build
    ./script/build-engine --force # rebuilds the engine (run, test and release rebuild it when the pin or a patch changed)
    ./script/build-engine --ios   # with the iOS slices too (test, run-ios and test-ios ask for them; run and release don't)
    ./script/release              # a Developer ID signed, notarized disk image in dist/

`script/build-engine` uses `$ZIG` if set, else Homebrew's `zig@0.16`, else the `zig` on `PATH`,
and stops unless it is version 0.16.

## Layout

    Sources/WorkspaceModel   windows, tabs, panes, pins, projects and the split tree; session JSON (no AppKit)
    Sources/Preferences      settings.json, terminal.conf generation, shortcuts, theme catalog
    Sources/CommandEditing   the input bar's logic: zsh integration, history, completion, vi mode, git status
    Sources/CommandBlocks    command blocks: where each command and its output start and end
    Sources/PaneActivity     what runs in a pane: foreground process, known programs and agents, repositories
    Sources/GhosttyBridge    the only code that touches libghostty on the Mac
    Sources/GhosttyMirror    the iPhone's libghostty: a surface fed a pane's bytes, no shell (iOS only)
    Sources/AgentHooks       agents' hook messages, the socket the app listens on, the hook state, Claude's settings merge
    Sources/promptty-hook    the helper agents' hooks run, bundled in the app; sends one line to the socket
    Sources/RemoteControl    the control socket's requests and responses, its server and client, `promptty`'s argument parsing
    Sources/promptty         the `promptty` command line, bundled in the app
    Sources/RemoteProtocol   the messages the Mac's remote API and the iPhone app send each other
    Sources/RemoteServer     the remote API's WebSocket server and who it lets in (Mac only)
    Sources/RemoteClient     the iPhone app's side of the remote API
    Sources/PrompTTYChrome   SwiftUI chrome the Mac and iPhone apps share: program tiles and logos, activity, rows, banner
    Sources/PrompTTYApp      AppKit windows and menus; SwiftUI chrome, input bar and Settings
    Engine/                  libghostty as a local SwiftPM package; patches/ holds PrompTTY's engine patches
    iOS/                     the iPhone and iPhone Duo app (PrompTTYPhone) and its UI tests
    script/                  bootstrap, run, test, build-engine, release, drive, run-ios, test-ios
    packaging/               the disk image's background and layout

### Portable modules

The iPhone app shares PrompTTY's own modules, so these build for iOS as well as macOS:
`WorkspaceModel`, `Preferences`, `CommandBlocks`, `CommandEditing`, `PaneActivity`, `AgentHooks`,
`RemoteControl`, `RemoteProtocol`, `RemoteClient` and `PrompTTYChrome`. Their Mac-only parts are behind `#if os(macOS)`: `ProcessRunner`'s running
of a program (its `Outcome` is shared), the hook listener (`HookListener`) and the control server
(`ControlServer`), and `PaneActivity`'s process inspection (`ListeningPorts`,
`ProcessTree.snapshot`, `ProcessArguments.read` and `.workingDirectory`). `script/test` builds the
portable modules for the iOS Simulator, so a Mac-only API slipping into one fails it.
`GhosttyBridge`, `PrompTTYApp`, `promptty` and `promptty-hook` are macOS only; only
`GhosttyBridge` and, for iOS, `GhosttyMirror` import GhosttyKit.

`PrompTTYChrome` is the SwiftUI chrome both apps draw with: `ProgramStack` and `ProgramIcon` (the
program logos are its asset catalog), `ActivityIndicator`, `WorkingDots`, `ProgressRing`,
`RowBackground`, `FlatSurface`, `HeaderButton`, the input bar's `HeaderChipStyle` and `BannerView`.
Its looping animations run in Core Animation on both platforms (`LoopingLayerView` hosts them in an
`NSView` or a `UIView`), so neither app drives a SwiftUI `repeatForever` from the main thread.

## The iPhone app

`iOS/PrompTTYPhone` is PrompTTY for iPhone and iPhone Duo: the Mac's tabs and panes, drawn with the
Mac's own chrome (`PrompTTYChrome`) and its theme (`ThemeCatalog`). It connects to a Mac's remote API
(Settings › Tabs › Remote access) with `RemoteClient` (`Sources/RemoteClient`), by the Mac's
Tailscale name, added in the Mac switcher and kept on the phone (`SavedMacs`). `MacConnection`
subscribes to the workspace and keeps the sidebar in step with its events (`RemoteMapping`), reads
the output of a pane's newest commands with `capture` and shows them as blocks (the live terminal
is PTY-78), runs what the input bar sends with `send`, and answers an agent's permission prompt
with `answer`: the banner's buttons are the prompt's choices as the Mac's screen shows them. Gone, it tries again every 5 seconds.
A real Mac's tabs are behind Face ID (or the passcode), at launch and each time the app comes back;
Settings (the gear) turns that off. The Demo Mac is scripted (`DemoData`): no connection, and its
permission prompt can be answered.

    script/run-ios                                build and launch on the "iPhone Duo" simulator
    script/run-ios "iPhone 18 Pro" -open zsh      another simulator; launch arguments after its name
    script/test-ios                               the UI smoke tests, on an iPhone simulator

It lays itself out for how the phone is held (`Posture`): phone-width (an iPhone, or an iPhone Duo
folded) shows the sidebar and opens a pane over it; an open iPhone Duo shows the sidebar beside the
pane; half-folded (the hinge part-way open, from `UIHingeInteraction` on iOS 27.1) puts the pane
above the hinge and the controls below it. The simulator cannot unfold an iPhone Duo from the
command line, so the launch arguments can force a posture and a canvas the app lays itself out in,
scaled to fit: `-posture flat -canvas 951x669` (open) and `-posture halfFolded -canvas 669x951`.
`-open <tab>` opens a tab (by title, or a pane's label) and `-activity YES` shows the Activity;
`-connect <host>` adds and shows a Mac, `-demo YES` shows the demo whatever was shown last, and
`-requireFaceID NO` skips the lock.

To try it against the Mac without a second device: start a Debug build of the Mac app with
`PROMPTTY_REMOTE_HOST=127.0.0.1` (it listens on the loopback address, which the Simulator shares),
turn on Remote access, and `script/run-ios "iPhone 18 Pro" -connect 127.0.0.1`.
`TEST_RUNNER_PROMPTTY_LIVE_MAC=1` runs `LiveMacTests` too, which types a command on the phone and
waits for its output from the Mac (it needs a pane labelled `gitlog`).

## Remote protocol

`Sources/RemoteProtocol` is the reference for what the Mac and the iPhone app say to each other;
both import it, so they cannot drift apart. It is JSON-RPC 2.0, one message per WebSocket text
frame (`RemoteMessage`: a request, its response, or a notification for an event).

- The first request on a connection is `hello` (`Hello` → `Welcome`), which compares protocol
  versions: `RemoteProtocol.version`, raised when a message changes in a way an older peer would
  misread. A version the Mac cannot speak gets `RemoteError.unsupportedVersion`, with the versions
  it can in the error's data.
- The control socket's commands are methods of the same names (`ls`, `send`, `capture`, …), their
  params `ControlParams` (`promptty`'s arguments without the command and the caller pane) and their
  result the control socket's own `ControlResponse`. A command that runs and fails is a result with
  the status `promptty` would exit with, not an error; errors are the protocol's own (JSON-RPC's
  codes, and PrompTTY's from -32001 down).

- `subscribe` answers with the workspace as the sidebar shows it (`RemoteWorkspace`: windows,
  projects, tabs and panes, each pane's program, state, agent tool, unseen output, ports, ssh host
  and newest commands; times in Unix seconds). From then on the Mac sends events, which ask for no
  answer: `workspace` with the whole workspace again whenever it changed (looked at twice a second
  while a device is connected, sent only when different, so a change arrives within a second), and
  `command.finished` when a command ends in a pane. `unsubscribe` stops them.
- `blocks` lists a pane's newest commands (`BlocksParams` → `BlocksResult`); a command's output is
  `capture` with its id as `cmd`, as text or with `markdown`.
- A pane whose agent waits for permission carries its `prompt` (`RemotePrompt`: what it asks and its
  numbered choices), read off its screen by `PromptReader` (`Sources/PaneActivity`). `answer`
  (`AnswerParams` → `AnswerResult`) presses a key there as the user would at the Mac: a choice's
  digit, `return`, `escape`, `y`, `n` or `interrupt` (`PromptKey`, `answerPrompt` in GhosttyBridge).
  A pane that waits for nothing refuses it (`notWaiting`, -32004), so a late tap types nothing.

Every message is pinned by a fixture in `Tests/RemoteProtocolTests/Fixtures`, so a change to the
wire format shows in review; `PROMPTTY_RECORD_FIXTURES=1 swift test --filter RemoteProtocolTests`
writes them again. Features that add messages (subscriptions, prompt answers, mirroring) add them
here, with fixtures.

### The phone's terminal

iOS can't start a shell, so the phone's terminal is a libghostty surface the app feeds:
`GhosttyMirror`'s `MirrorSurfaceView` (engine patch 0006, `Engine/patches/README.md`). `feed(_:)`
puts a pane's output on screen; `onWrite` gets what the terminal sends the program (typing, the key
row, pastes, taps as mouse reports, and its own replies to the program's queries) and `onResize`
the grid the phone has room for. It is Metal-drawn by libghostty, as on the Mac. Its config is the
Mac's `terminal.conf` with the theme inline (the phone has no theme files) and `SF Mono` mapped to
the iOS system monospaced font (`MirrorEngine.phoneConfig`). The engine's iOS slices come from
`script/build-engine --ios`.

Until the Mac streams panes, a Debug build shows it on its own: `script/run-ios "iPhone 18 Pro"
-mirror vim` (or `-mirror claude`) plays a recording of what vim or Claude Code wrote to its pty on
the Mac (`iOS/PrompTTYPhone/Debug/Recordings`, made on a 54×40 pty; the terminal is sized to that
grid first), with every byte the terminal sends back shown under it. `MirrorTests` (in
`script/test-ios`) types on it and checks the bytes.

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

## Remote access

Settings › Tabs › Remote access (off by default) starts the remote API (`Sources/RemoteServer`,
started by `RemoteAccess`): a WebSocket server on Network.framework speaking `RemoteProtocol`, on
port 7445 of the Mac's Tailscale address only, so nothing outside the tailnet reaches it. Off,
nothing listens. Without Tailscale running it waits and tries again every 30 seconds; Settings
shows the address to connect to and the devices connected, each with Disconnect.

- **Who gets in** is decided as Rex decides it: Tailscale names each caller (`tailscale whois`) and
  only the Mac's owner (`tailscale status`'s own user), from a device of their own rather than one
  owned by an ACL tag, is let in (`TailnetIdentity`). Anyone else gets a `notAllowed` error and is
  hung up on before anything they send is read. There is no pairing and no keys of PrompTTY's own.
- **What it answers**: `hello` first (`RemoteSession`), then the control socket's commands, answered
  by the same handler as `promptty`'s (so Settings › Tabs › Command line must be on too).
- **Limits** as the control socket's: at most 64 connections, messages up to 1 MB, 10 s to say hello.

A connection from the Mac to its own Tailscale address does not complete with Network.framework's
listener (the listener sees it, the handshake never finishes; a BSD socket on the same address is
reached), so try it from another device on the tailnet. The tests run the server on the loopback
address with a stand-in for Tailscale. A Debug build started with `PROMPTTY_REMOTE_HOST=127.0.0.1`
listens on the loopback address instead and takes every caller for the owner, for driven runs
(`eval settings remote on`, `eval remote`) and the iPhone app in the Simulator.

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
