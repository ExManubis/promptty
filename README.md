# PrompTTY 2

A native macOS terminal built on [libghostty](https://ghostty.org), the engine behind Ghostty,
with a Liquid Glass interface in SwiftUI: tabs in a floating sidebar or a strip, splits as
separate rounded cards, and a Settings window. The window frame takes its color from the
terminal theme. The default theme is [Flexoki](https://github.com/kepano/flexoki), following the
system's light and dark appearance.

This is the start of a larger agent-workspace project. See `docs/superpowers/specs/` for designs.

## Build

Requires macOS 26 and Xcode 26 or newer. No Zig: libghostty arrives as a prebuilt
xcframework through SwiftPM.

    ./script/bootstrap   # installs xcodegen if needed, resolves packages, generates the Xcode project
    ./script/run         # builds Debug and launches the app
    ./script/test        # library tests, then an app build

## Settings

Everything is in **PrompTTY › Settings…** (⌘,) and applies immediately:

- **Appearance:** font family and size, light and dark themes (every theme bundled with
  Ghostty), cursor, how strongly the frame follows the theme color.
- **Tabs & Windows:** sidebar or strip, sidebar width, folder for new tabs, session restore,
  close confirmation.
- **Keyboard:** Option as Alt, and every shortcut below.

Settings are stored in `~/Library/Application Support/PrompTTY/settings.json`. From them the app
writes `terminal.conf`, the only config libghostty reads. PrompTTY does not read
`~/.config/ghostty/config`.

## Keys

PrompTTY claims only shortcuts that contain ⌘. Every ⌃, ⌥ and ⌃⇧ combination goes to the
terminal untouched, so programs like Neovim get them, and Option acts as Alt by default.
libghostty itself binds nothing (`keybind = clear`).

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

All of these can be changed in Settings › Keyboard.

## Splits

Drag the gap between two panes to resize; double-click it to make both sides equal. Hover near
the top of a pane for its header: drag the handle (☰) onto the edge of another pane, onto a tab in
the tab list, or into another window to move the pane there. Its shell keeps running.

## Layout

    Sources/WorkspaceModel   windows, tabs, panes and the split tree; session JSON (no AppKit)
    Sources/Preferences      settings.json, terminal.conf generation, shortcuts, theme catalog
    Sources/GhosttyBridge    the only code that touches libghostty
    Sources/PrompTTYApp      AppKit windows and menus; SwiftUI chrome and Settings

## Debug driver

Debug builds can be driven without Screen Recording or Accessibility access, which is how the UI
is checked in automated runs:

    ./script/drive start /tmp/ptty                 # launch with its own data folder
    ./script/drive run /tmp/ptty commands.txt      # actions, keys, typing, window snapshots
    ./script/drive stop /tmp/ptty

See `Sources/PrompTTYApp/Debug/DebugDriver.swift` for the command list.
