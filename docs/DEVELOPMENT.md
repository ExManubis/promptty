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
subscribes to the workspace and keeps the sidebar in step with its events (`RemoteMapping`), and
answers an agent's permission prompt with `answer`: the banner's buttons are the prompt's choices
as the Mac's screen shows them. The open pane is live (`LiveMirror`, `LiveTerminal`): attached
with `attach`, drawn by the phone's libghostty (`GhosttyMirror`) with the Mac's font and theme
(`appearance`) at the pane's grid, zoomed out to the card's width (pinch to zoom, two fingers to
move, one to scroll its scrollback). What is typed goes to the pane as keys (`input`, the view's
`onInput`), with the key row's Control and Option on the next key; "Take control" sizes the pane
to the card until "Let go", or until the pane is clicked on the Mac. The "+" under the pane opens a
tab on the Mac for the phone (`NewTabSheet`, `places`): a shell in a folder ⌘J knows, an ssh host,
or a saved command, labelled iPhone, taken control of at once so it runs at the phone's size; it
stays open on the Mac when the phone goes. Typing needs Settings › Tabs › Remote access › typing on the Mac;
without it the pane is view only. Gone, it tries again every 5 seconds and resumes the pane where
it got to.
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

**Mirroring a pane** (`Mirror.swift`) shows a live terminal on the device. A pane's output is one
stream of bytes, named by `stream` (a UUID) and counted from 0 by `seq`:

- `attach` (`AttachParams`: the pane as `-p` names one, `scrollback` rows, 1000 by default) answers
  with `Attached`: the pane's id, a `position` (stream and seq), a `snapshot` and the pane's
  `MirrorState`. The snapshot is VT bytes, base64 like every byte in the protocol: fed to a fresh
  terminal of the state's `cols`×`rows`, they rebuild the Mac's (a full reset, the scrollback, the
  screen, the cursor and its style, the modes such as the alternate screen with the shell's screen
  behind it, cursor visibility, bracketed paste and mouse reporting, the scrolling region, tab
  stops, the colors programs changed, and the escape sequence the output stopped in the middle of).
  It holds exactly the output before `seq`.
- Then `output` events (`MirrorOutput`): the bytes from their `seq` on, as the programs wrote them,
  at most 64 KiB each, each starting where the last ended. A gap means bytes were lost: attach
  again. Feeding them to the same terminal keeps it the Mac's.
- A client that reconnects attaches with `resume` (the stream and the seq it got to) and, while the
  Mac still has those bytes (the last 2 MB of each pane, kept a minute after its last client
  goes), gets `Attached` without a snapshot and the bytes it missed; otherwise a fresh snapshot.
- `pane.state` (`MirrorState`) comes when the pane's grid, its controller, its password prompt (the
  program turned echo off: a client hides what it echoes) or whether the client may type changes;
  `seq` says about where in the output a new size begins. `detached` (`Detached`) says the Mac
  stopped mirroring the pane to the client: it `closed`, the client fell `behind` (more than 8 MB of
  output waiting to be sent to it), or remote access `stopped`.
- `input` (`InputParams`) types `text` as key presses (Return, Tab, Escape and control characters as
  those keys), pastes `paste` (bracketed when the program asked for that), or presses a `key`
  (`RemoteKey`: a named key or one character, with `shift`, `ctrl`, `alt`, `super`), through the
  surface's key input as the Mac's keyboard does. Only while Settings allows typing
  (`typingOff` otherwise).
- By default a client sees the pane at the Mac's size. `control.take` (`ControlTake`: the client's
  grid) resizes the pane to the client's grid until it sends `control.release`, detaches or
  disconnects; then the pane gets the Mac's size back. One client has control at a time: taking it
  takes it from the one that had it, and every attached client is told. `resize` changes the grid
  while in control (`notInControl` otherwise). Several clients can attach to a pane at once, each
  scrolling its own terminal.
- `detach` stops it. Mirror methods on a pane not attached to answer `notAttached`.

The messages name panes and streams, not connections, so a daemon speaking for a Mac (PTY-77) can
send them unchanged.

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
- **Mirroring** (`MirrorHub`, with each pane's `MirrorFeed`; the app's side in
  `WorkspaceCoordinator+Mirror.swift`): a device can always watch a pane; typing into one is a
  setting of its own under Remote access, off by default. A pane mirrored shows a badge at its
  bottom right with the devices watching it, orange while one has control: then the terminal keeps
  the device's grid whatever its pane's size (`TerminalSurfaceView.gridOverride`), drawn from the
  top left. The snapshot is libghostty's (`ghostty_surface_read_vt_snapshot`, patch 0006), taken
  with the terminal locked and lined up with the output tap (patch 0005) by `TerminalOutput`'s byte
  count, read in the same lock, so the snapshot and the bytes after it never overlap or leave a
  gap. The output goes to each client as it is read; one with more than 8 MB waiting is detached
  (`behind`). A snapshot is as big as its scrollback (1000 rows of colored text are a few hundred
  KB): a client raises its WebSocket's message limit (URLSession's is 1 MB) or asks for less.

A connection from the Mac to its own Tailscale address does not complete with Network.framework's
listener (the listener sees it, the handshake never finishes; a BSD socket on the same address is
reached), so try it from another device on the tailnet. The tests run the server on the loopback
address with a stand-in for Tailscale. A Debug build started with `PROMPTTY_REMOTE_HOST=127.0.0.1`
listens on the loopback address instead and takes every caller for the owner, for driven runs
(`eval settings remote on`, `eval remote`) and the iPhone app in the Simulator;
`PROMPTTY_REMOTE_PORT` moves it off 7445, for two driven runs at once.

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
