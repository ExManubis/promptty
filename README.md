# PrompTTY 2

A native macOS terminal built on [libghostty](https://ghostty.org), the engine behind Ghostty,
with a SwiftUI interface in the style of the Dia browser: a flush sidebar (or a tab strip), each
pane in its own rounded card, and a Settings window.
The default theme is [Flexoki](https://github.com/kepano/flexoki), following the system's light
and dark appearance.

This is the start of a larger agent-workspace project. See `docs/superpowers/specs/` for designs.

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

## Settings

Everything is in **PrompTTY › Settings…** (⌘,) and applies immediately:

- **Appearance:** font family and size, light and dark themes (every theme bundled with
  Ghostty), cursor style and color (the theme's, the system accent or a custom one), how much of
  the theme's color the window frame takes on (neutral by default), and whether ProMotion
  displays stay at 120 Hz while a PrompTTY window is in front.
- **Tabs & Windows:** sidebar or strip, sidebar width, folder for new tabs, session restore,
  close confirmation, and clipboard access by programs.
- **Keyboard:** Option as Alt, vim-style navigation, and every shortcut below.
- **Agents:** installing or removing Claude Code's hooks, and the line for Codex (see
  [Agent hooks](#agent-hooks)).

**PrompTTY › Secure Keyboard Entry** keeps other apps from seeing keystrokes while PrompTTY is in
front (a checkmark; remembered). Separately, whenever a program asks for it, as a password prompt
does, secure input is on while that pane has the keyboard, and a lock shows at the pane's corner.

**Clipboard access:** a program that asks to read or write the clipboard (OSC 52) is asked about
in a banner over its pane ("<program> wants to read the clipboard"): Allow, Deny, or Always allow
for this pane. Settings › Tabs & Windows sets reading and writing to Ask (default), Allow or Deny.

**Progress:** a program that reports progress (OSC 9;4, as `winget`, `systemd` or `printf '\e]9;4;1;40\a'`
do) gets a small ring on its tab's row and, for an agent, on the agent's row: filled to the percent,
spinning while indeterminate, red on an error, yellow when paused. It goes when the program removes
it, the command finishes, or 15 s pass without an update.

Settings are stored in `~/Library/Application Support/PrompTTY/settings.json`. From them the app
writes `terminal.conf`, the only config libghostty reads. PrompTTY does not read
`~/.config/ghostty/config`.

## Keys

PrompTTY claims only shortcuts that contain ⌘, plus the vim-style navigation keys below. Every
other ⌃, ⌥ and ⌃⇧ combination goes to the terminal untouched, so programs like Neovim get them,
and Option acts as Alt by default. libghostty itself binds nothing (`keybind = clear`).

| Action | Keys |
|---|---|
| New window / close window | ⌘N / ⇧⌘W |
| New tab / close tab | ⌘T / ⌥⌘W |
| Next / previous tab, go to tab 1–9 | ⇧⌘] / ⇧⌘[, ⌘1…⌘9 |
| Toggle sidebar / sidebar or strip | ⌘B / ⌃⌘S |
| Split right / split down | ⌘D / ⇧⌘D |
| Close pane (the last pane closes the tab) | ⌘W |
| Move focus between panes | ⌥⌘← ↑ → ↓ |
| Equalize panes | ⌃⌘= |
| Zoom the focused pane (press again, or move focus, split or close, to go back) | ⇧⌘↩ |
| Copy, paste, select all, clear | ⌘C, ⌘V, ⌘A, ⌘K |
| Bigger / smaller / actual size | ⌘= / ⌘- / ⌘0 |
| Select previous / next command | ⌘↑ / ⌘↓ |
| Select previous / next failed command | ⌃⌘↑ / ⌃⌘↓ |
| Copy the selected command's output / the command | ⌥⌘C / ⇧⌘C |
| Rerun the selected command (puts it in the input bar; Return runs it) | ⇧⌘R |

All of these can be changed in Settings › Keyboard.

⌘-click opens a link or file path in the terminal's output, and `path:line:col` works too. Web and
mail links open directly; other kinds (ssh, smb, custom app schemes) ask first; `javascript:` and
`data:` are refused. Text, source, images, PDFs, audio and video open in their app, folders in
Finder, other files are shown in Finder. Programs, applications and launchable files are never
run, and ⌘-clicking one beeps. While the pointer is over a link, its address shows at
the pane's bottom-left.

Vim-style navigation is on by default and can be turned off in Settings › Keyboard (its keys are
fixed): ⌥H/J/K/L move focus to the pane on that side, ⌥⇧J/K go to the next and previous tab.
With it on, those keys never reach the terminal.

## Input bar and command blocks

When your login shell is zsh, each idle pane shows a native input bar in place of the shell's
prompt. Above it are the folder and git branch, the last command's duration (from a second) and
its exit code (when it failed); the folder and branch buttons open pickers. The bar has history
(↑/↓), ghost-text suggestions, Tab completion, syntax coloring and vi mode (when you use
`bindkey -v`). ⌃R opens a fuzzy search over the history, newest first, with the commands you ran in
the current folder on top; ⏎ puts the chosen command in the bar without running it, ⌃R again moves
to the next match, ⎋ closes. While a program runs (`nvim`, `ssh`, `sudo`, a REPL) the bar is gone and every key
goes to the terminal.

PrompTTY loads its zsh integration through `ZDOTDIR` and then your own files. Other shells get a
plain terminal.

Each command and its output form a block: ⌘↑/⌘↓ select one (⌃⌘↑/⌃⌘↓ jump between the ones that
failed), ⌥⌘C copies its output and ⇧⌘C its command. The buttons on the block under the pointer, and
its right-click menu, also copy the block as Markdown (the command and output in a `console`
fence) and rerun it: the command goes into the input bar, not run until you press Return, and only
while the pane is at a prompt.

## Tabs, projects and agents

**Projects** organize the Agents section: named groups the agents are listed under. They are
not folders, and the tab list stays one flat list. Make one with **New Project…** (File menu,
right-click "Agents", or an agent's or a tab's **Move to Project** menu). Drag an agent onto a
project's header to move it there (its tab joins the project, so later agents in that tab do too);
drag a header onto another to reorder the projects. A header's menu renames the project, gives it
an icon, moves it up or down, or removes it; its "+" opens a tab in the project, for an agent to
start in. Every project shows, even with no agents running. ⌘T opens the new tab in the selected
tab's project. Projects are saved with the session.

Drag tabs to reorder them. **Pin Tab** (in a tab's context menu, or drag it onto the pinned
tiles) keeps the tab's folder and the command running in it (`claude`, `npm run dev`): a pinned
tab comes back on relaunch, restarts instead of closing, and can be reset, given another command,
or given its own icon (**Change Icon…**).

PrompTTY recognizes coding agents (Claude Code, Codex, Amp, Cline and others) running in a pane.
While any run (or projects exist), the top of the sidebar lists every agent in every window, with
whether it is working, waiting or wants your turn, and since when; click one to bring its pane
forward, or right-click it to rename its tab or move it to a project. Agents are grouped under
their projects, in order, then (outside any project) by git repository. The agent in the window's focused pane is
highlighted like its tab.

### Agent hooks

Without help PrompTTY guesses an agent's state from its screen (still for three seconds: your
turn). With **Claude Code's hooks** it knows: when you send a prompt, which tool runs ("Working ·
Bash"), when a permission prompt waits for you (an orange shield, "Needs permission", and a
notification naming it), when it asks you a question or has a plan for you to approve
("Waiting", and a notification) and when the turn ends ("Your turn", and a "Done after …" notification
when it took 10 s or more and you were looking elsewhere). **Settings › Agents › Install Claude
Code Hooks…** shows what it will change, then adds one hook per event (SessionStart, SessionEnd,
UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop, SubagentStop) to
`~/.claude/settings.json`, each running `'<PrompTTY.app>/Contents/MacOS/promptty-hook' <Event>`.
It keeps every other setting and hook (the file is rewritten with its keys sorted), copies the
file to `settings.json.bak` first (or, when that backup exists already, to a dated
`settings.json.bak-<date>`, so the original survives), and installing again changes nothing; **Remove…** takes out only PrompTTY's entries (any command
running a `…/promptty-hook`). Nothing is written until you click. Claude Code sessions started
afterwards use the hooks.

How it works: every pane, whatever its shell, starts with `PROMPTTY_PANE_ID` (the pane's id) and
`PROMPTTY_SOCKET` (`hooks.sock` in the app's data folder, mode 0600; if that path is longer than
a Unix socket allows, `promptty-<hash of the folder>.sock` in the temporary folder instead).
`promptty-hook` reads the hook's JSON from standard input, keeps only the fields PrompTTY uses
(session id, transcript path, folder, tool name, notification text; never the prompt or a tool's
input), and sends them with the pane's id as one line to the socket. It prints nothing, always
exits 0, gives up after 200 ms and does nothing outside PrompTTY. The app accepts only processes of
the same user. While a pane's hooks report, they decide its agent's state and its screen is not
watched; without hooks, or after ten minutes without one once the agent has gone, the screen is
watched again. Return, Esc, y, n, a digit or ⌃C pressed at a permission prompt counts as the answer.
An interrupted turn (Esc, ⌃C, a prompt answered "no") runs no hook: while the hooks say the agent
works, a screen still for 3 s with no hook for 5 s ends the turn, without a notification. If
another PrompTTY already listens on the socket (two copies sharing a data folder) it is left
alone. Programs started from a pane inherit its variables, so an agent in a tmux session or an
editor's terminal reports to the pane that started tmux or the editor; a limitation: those
reports are ignored, as a pane shows an agent's state only while the agent itself is in front
(there, tmux or the editor is). The hooks name the app by its path: after moving PrompTTY.app, or
when macOS runs it from a temporary copy (App Translocation, for an app opened where it was
downloaded), they find nothing to run until you install them again from Settings › Agents.

For **Codex**, add `notify = ["<PrompTTY.app>/Contents/MacOS/promptty-hook", "codex-notify"]` at
the top of `~/.codex/config.toml` (Settings › Agents shows the line with the path filled in): the
end of each turn is then exact, while its work is still read from the screen.

## Splits

Drag the gap between two panes to resize; double-click it to make both sides equal. Split, close
and move focus between panes with the shortcuts above.

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

## Debug driver

Debug builds can be driven without Screen Recording or Accessibility access, which is how the UI
is checked in automated runs:

    ./script/drive start /tmp/ptty                 # launch with its own data folder
    ./script/drive run /tmp/ptty commands.txt      # actions, keys, typing, window snapshots
    ./script/drive stop /tmp/ptty

See `Sources/PrompTTYApp/Debug/DebugDriver.swift` for the command list.
