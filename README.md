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
  close confirmation.
- **Keyboard:** Option as Alt, vim-style navigation, and every shortcut below.

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
| Copy, paste, select all, clear | ⌘C, ⌘V, ⌘A, ⌘K |
| Bigger / smaller / actual size | ⌘= / ⌘- / ⌘0 |
| Select previous / next command | ⌘↑ / ⌘↓ |
| Copy the selected command's output / the command | ⌥⌘C / ⇧⌘C |

All of these can be changed in Settings › Keyboard.

Vim-style navigation is on by default and can be turned off in Settings › Keyboard (its keys are
fixed): ⌥H/J/K/L move focus to the pane on that side, ⌥⇧J/K go to the next and previous tab.
With it on, those keys never reach the terminal.

## Input bar and command blocks

When your login shell is zsh, each idle pane shows a native input bar in place of the shell's
prompt. Above it are the folder and git branch, the last command's duration (from a second) and
its exit code (when it failed); the folder and branch buttons open pickers. The bar has history
(↑/↓), ghost-text suggestions, Tab completion, syntax coloring and vi mode (when you use
`bindkey -v`). While a program runs (`nvim`, `ssh`, `sudo`, a REPL) the bar is gone and every key
goes to the terminal.

PrompTTY loads its zsh integration through `ZDOTDIR` and then your own files. Other shells get a
plain terminal.

Each command and its output form a block: ⌘↑/⌘↓ select one, ⌥⌘C copies its output and ⇧⌘C its
command.

## Tabs, projects and agents

**Projects** group tabs in the sidebar under a name and a folder. Make one with **New Project…**
(File menu, a tab's **Move to Project** menu, or the "+ New Tab" row's menu); it starts at the
selected tab's repository. ⌘T opens the new tab in the selected tab's project; a project header's
"+" opens one in the project's folder; "+ New Tab" opens one in no project. Drag a tab onto a
project's header or among its tabs to move it there; drag a project's header onto another's to
reorder the projects. A project's menu renames it, gives it an icon or another folder, moves it up
or down, or removes it (its tabs stay open). Projects and the tabs
in them are saved with the session; in the tab strip a thin line separates them.

Drag tabs to reorder them. **Pin Tab** (in a tab's context menu, or drag it onto the pinned
tiles) keeps the tab's folder and the command running in it (`claude`, `npm run dev`): a pinned
tab comes back on relaunch, restarts instead of closing, and can be reset, given another command,
or given its own icon (**Change Icon…**).

PrompTTY recognizes coding agents (Claude Code, Codex, Amp, Cline and others) running in a pane.
While any run, the top of the sidebar lists every agent in every window, with whether it is
working, waiting or wants your turn, and since when; click one to bring its pane forward. Agents are
grouped under the projects of their tabs, in sidebar order, then (for tabs in no project) by git
repository. Folding a project folds it in both places. Project headers there have the same menu and
drag the same way; drag an agent onto a project's header to move its tab into the project, or
right-click it to show it, rename its tab or move it to a project. The agent in the window's focused pane is
highlighted like its tab.

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
