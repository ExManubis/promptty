# PrompTTY 2: SwiftUI chrome, splits, and settings

**Date:** 2026-10-12
**Status:** Design, approved in conversation
**Builds on:** `2026-10-04-promptty2-mvp-design.md`

## Problem

The MVP chrome is about 850 lines of hand-laid-out AppKit (constraints, custom tab views,
layer drawing). It works, but it does not look or feel like a current Mac app, and every new
piece of UI costs more AppKit layout code. Two features the app needs next, splits and a
settings window, would grow that code a lot.

PrompTTY also inherits Ghostty's config and Ghostty's default keybinds. The default keybinds
intercept keys that should reach the shell, which breaks Neovim shortcuts that work in other
terminals.

## Goal

Rebuild the window contents in SwiftUI with a Liquid Glass look, SF Symbols and SF fonts, and
add in the same round:

1. **Splits:** several panes per tab, each its own rounded card, rearrangeable by drag.
2. **A Settings window:** Appearance, Tabs & windows, Keyboard.
3. **PrompTTY's own config:** no more reading `~/.config/ghostty/config`, and no Ghostty
   default keybinds. PrompTTY claims only ⌘ shortcuts.

## Decisions (locked)

These supersede the MVP spec where they conflict.

- **Approach A:** AppKit keeps the app lifecycle, `AppDelegate`, the main menu, and one
  `NSWindowController` + `NSWindow` per window. Everything inside the window, and the Settings
  window, is SwiftUI. No SwiftUI `WindowGroup` or scene-based window management.
- **macOS 26 minimum** (Liquid Glass APIs). `swift-tools-version` goes to 6.2,
  `platforms: [.macOS(.v26)]`, `MACOSX_DEPLOYMENT_TARGET: "26.0"`.
- **Liquid Glass over a theme-tinted backdrop.** The window backdrop is a solid color derived
  from the terminal theme's background. The desktop does not show through.
- **Splits are not restored on relaunch.** Each restored tab is one pane in the directory of
  the pane that was focused at save time.
- **PrompTTY's settings are the only config source.** `~/.config/ghostty/*` is never read. No
  one-time import from Ghostty.
- **Default theme: Flexoki** (kepano/flexoki), using Ghostty's bundled `Flexoki Light` and
  `Flexoki Dark`, following the system appearance.
- **Only ⌘ shortcuts.** The generated Ghostty config begins with `keybind = clear`. Every
  PrompTTY shortcut is a menu key equivalent containing ⌘. Option acts as Alt by default.
- libghostty stays the terminal engine, pinned as today via `libghostty-spm`.

## Out of scope

Pane zoom, panes nested in the tab list, restoring splits, a command palette, agent status,
a raw config editor, terminal-level keybinds (e.g. `text:` bindings), importing Ghostty
config, translucent windows, search in scrollback. The MVP backlog stays as it was, minus
splits.

## Architecture

```
PrompTTYApp (app bundle)
  ├── AppDelegate, MainMenu (AppKit)       menu built from ShortcutMap
  ├── TerminalWindowController (AppKit)    owns NSWindow + surface views
  ├── Chrome/ (SwiftUI)                    WindowRootView, sidebar, strip, pane tree, banner
  ├── Settings/ (SwiftUI)                  Settings window and its three sections
  ├── Preferences (new library)            settings.json, terminal.conf generation, shortcuts
  ├── WorkspaceModel                       + Pane, SplitNode; Tab owns a split tree
  └── GhosttyBridge                        + load config from a path, binding actions, split context
```

Only `GhosttyBridge` imports `GhosttyKit`. `WorkspaceModel` and `Preferences` import no UI
frameworks and are covered by unit tests.

## 1. Model: panes and split layout

New in `WorkspaceModel`:

- **`PaneID`**: `Hashable, Codable, Sendable` UUID wrapper, like `TabID`.
- **`Pane`** (`@MainActor @Observable`): `id`, `title` (from Ghostty `set_title`),
  `workingDirectory` (from `pwd`, or the launch directory).
- **`SplitAxis`**: `.horizontal` (side by side) or `.vertical` (stacked).
- **`SplitNode`**: an indirect value-type enum:
  - `.leaf(PaneID)`
  - `.split(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)`, where
    `ratio` is the share of `first`, clamped to `0.1...0.9`.

`Tab` changes:

- Gains `root: SplitNode`, `panes: [PaneID: Pane]`, and `focusedPaneID: PaneID`.
- `title` and `workingDirectory` become read-only, derived from the focused pane.
  `customTitle` and `displayTitle` keep their current meaning. Existing call sites that read
  `tab.title` keep working; writes go to the pane.
- A new tab starts as `.leaf` of one new pane.

Operations on `SplitNode` are pure functions with unit tests:

| Operation | Behavior |
|---|---|
| `splitting(_ pane:, direction:, newPane:)` | Replaces the leaf with a 0.5 split. `direction` is right/down/left/up; left/up put the new pane first. |
| `removing(_ pane:)` | Removes the leaf; its sibling takes the parent's place. Returns `nil` if it was the only leaf. |
| `neighbor(of:, direction:)` | Lays the tree out in a unit rect, then picks the pane whose frame is adjacent in that direction and overlaps most along the other axis. Ties go to the pane closest to the source's top-left. |
| `resizing(at path:, ratio:)` | Sets one split's ratio (clamped). |
| `equalized()` | Sets every ratio to 0.5. |
| `inserting(_ pane:, at target:, edge:)` | Splits `target` with `pane` on the given edge. Used by drag and drop. |
| `leaves` | Panes in reading order (left-to-right, top-to-bottom). |

`WindowState` gains `movePane(_:from:to:edge:)` for moves between tabs. Moving the last pane
out of a tab removes that tab, with the same selection rule as `closeTab`.

**Session snapshot:** format unchanged, version stays 1. `TabSnapshot` is written from the
focused pane's title and directory. `tabLayout` keeps being written for compatibility but is
no longer read once `settings.json` exists (see section 4).

## 2. Splits in the app

**Surfaces per pane.** `TerminalWindowController` keeps `surfaces: [PaneID: TerminalSurfaceView]`
and `TerminalSurfaceView.token` becomes the `PaneID`. SwiftUI only places surface views; it
never creates or destroys them, so changes in the view tree never restart a shell. The
coordinator's `locate(_:)` resolves a surface to `(WindowState, Tab, Pane, controller)`.

**Creating panes.** Split Right (⌘D) and Split Down (⇧⌘D), from the menu or the pane header.
The new pane's surface uses
`ghostty_surface_inherited_config(source, GHOSTTY_SURFACE_CONTEXT_SPLIT)`, so it inherits
the source pane's working directory. The new pane is focused.

**Focus.** Clicking a pane makes it focused and first responder. ⌥⌘←↑→↓ move focus with
`neighbor(of:direction:)`. The focused pane has a 1.5pt accent outline; unfocused panes get a
backdrop-colored overlay at 15% opacity. Focus changes update the tab's derived title and
directory, and the window title.

**Resizing.** The 6pt gap between two sibling cards is the divider for that split. Dragging
it resizes, with the resize cursor shown on hover. Double-clicking the gap equalizes that one
split. ⌃⌘= equalizes the whole tab.

**Drag to rearrange.**

- Each card shows a drag handle (`line.3.horizontal`) in its hover header. Dragging starts
  only from the handle, so mouse drags in the terminal stay text selection.
- The drag payload is a `Transferable` pane reference (window, tab, pane IDs), local to the
  app.
- Over another pane, the drop target's nearest edge (left, right, top, bottom) shows a
  half-pane highlight. Dropping calls `inserting(_:at:edge:)`.
- Dropping on a tab in the sidebar or strip moves the pane into that tab, to the right of its
  focused pane, and selects that tab.
- Dropping into another window moves the surface view to that window's controller. The
  libghostty surface and its shell keep running.
- Dropping a pane onto itself does nothing.

**Closing.**

- ⌘W closes the focused pane through `ghostty_surface_request_close`, so libghostty's
  running-process confirmation flow applies. The last pane closes the tab.
- ⌥⌘W closes the tab (every pane). ⇧⌘W closes the window, as today.
- `showChildExited` and `closeSurface(processAlive:)` now apply to the pane, not the tab.

## 3. Chrome in SwiftUI with Liquid Glass

**Window.** `TerminalWindowController` keeps the current `NSWindow` setup (full-size content
view, transparent titlebar, hidden title, system traffic lights, `tabbingMode = .disallowed`).
`window.contentView` becomes an `NSHostingView` of `WindowRootView`, which observes the
`WindowState`, the `Workspace`, and `Preferences`.

**`WindowRootView`** is a `ZStack`:

1. **Backdrop:** a solid `Color` from `ChromeTint` (logic unchanged; it now derives from the
   active theme's background in settings, and an OSC 11 from the selected tab still overrides
   it for that window).
2. **Layout:** sidebar or strip, plus the pane area (banner on top, then the pane tree).

**Sidebar** (`SidebarView`): a floating glass panel, `.glassEffect` in a
`GlassEffectContainer`, inset 8pt from the window edges, width from settings (default 220pt).

- Header row level with the traffic lights: `sidebar.left` (hide sidebar, ⌘B) and `plus`
  (new tab).
- Tab row: `terminal` symbol; title in SF Pro 13 medium; abbreviated directory below in
  SF Pro 11, secondary color; `rectangle.split.2x1` badge when the tab has splits.
- Selected row: glass pill tinted with the accent color. Hover shows an `xmark` close button.
- Double-click renames inline (`TextField`); Return commits, Escape cancels, focus returns to
  the terminal. Drag rows to reorder.

**Strip** (`TabStripView`): glass capsule tabs in a horizontal row, starting to the right of the
traffic lights, with the same row content (no directory line), and `plus` at the end. Scrolls
horizontally on overflow. ⌃⌘S switches sidebar and strip with a spring animation.

**Pane tree** (`PaneTreeView`): recursive over `SplitNode`, with `GeometryReader` for split
ratios. Each leaf is a `PaneCard`:

- `PaneHost`, an `NSViewRepresentable` whose `makeNSView` returns a plain container `NSView`
  and whose `updateNSView` installs the pane's cached `TerminalSurfaceView` in it if it is not
  already there.
- The 12pt rounded corners are applied in AppKit (`layer.cornerRadius`, `masksToBounds` on the
  container), not with SwiftUI clipping, because the surface draws into a `CAMetalLayer`.
- Hover header: a small glass capsule along the card's top edge, visible only while the
  pointer is in the top 28pt of the card or over the header. Left: drag handle. Right:
  `rectangle.split.2x1` (split right), `rectangle.split.1x2` (split down), `xmark` (close pane).
- Hidden tabs' surfaces stay alive, unmounted, and occluded, as in the MVP.

**Banner** (`BannerView`, replacing the uncommitted AppKit `BannerView.swift`): a glass capsule
at the top of the pane area with `exclamationmark.triangle.fill`, the message, and an optional
action button. Same coordinator logic as today: a persistent config/settings banner and
6-second transient banners.

**Exited overlay:** a centered glass panel in the pane: "Process exited (code N)" and a Close
button.

**Type and symbols.** All chrome text uses the system font (SF Pro) at system sizes. All icons
are SF Symbols. No custom images in the chrome.

**Motion and accessibility.** Spring animations for layout switching, tab insert and removal,
and split changes, disabled under Reduce Motion. Glass falls back automatically under Reduce
Transparency. All buttons have accessibility labels and help tooltips.

## 4. Preferences and PrompTTY's config

New SwiftPM library **`Preferences`** (Foundation only, `@MainActor @Observable` model).

**Files** in `~/Library/Application Support/PrompTTY/`:

- `settings.json`: the source of truth. Versioned (`version: 1`), written debounced on change
  using the existing `DebouncedSaver` pattern, with `.bak` recovery like `SessionStore`.
- `terminal.conf`: generated from settings on every change, in Ghostty config syntax. Never
  edited by hand; overwritten freely.

**Settings model:**

| Group | Field | Default |
|---|---|---|
| Appearance | `fontFamily` | `SF Mono` |
| | `fontSize` | 13 |
| | `followSystemAppearance` | true |
| | `lightTheme` / `darkTheme` | `Flexoki Light` / `Flexoki Dark` |
| | `theme` (used when not following the system) | `Flexoki Dark` |
| | `cursorStyle` (block, bar, underline) | block |
| | `cursorBlink` | true |
| | `tintStrength` (0–1, how strongly the backdrop follows the theme) | 0.5 |
| Tabs & windows | `tabLayout` (sidebar, strip) | sidebar |
| | `sidebarWidth` (180–320) | 220 |
| | `tabListHidden` | false |
| | `newTabDirectory` (currentPane, home) | currentPane |
| | `restoreSession` | true |
| | `confirmCloseRunning` | true |
| Keyboard | `optionAsAlt` (both, left, right, off) | both |
| | `shortcuts` (action → shortcut overrides; absent = default) | empty |

**Generated `terminal.conf`**, in this order:

```
keybind = clear
font-family = <fontFamily>
font-size = <fontSize>
theme = light:<lightTheme>,dark:<darkTheme>      # or theme = <theme>
cursor-style = <cursorStyle>
cursor-style-blink = <cursorBlink>
macos-option-as-alt = <true|left|right|false>
confirm-close-surface = <confirmCloseRunning>
```

App-only settings (`tabLayout`, `sidebarWidth`, `tabListHidden`, `newTabDirectory`,
`restoreSession`, `tintStrength`) are not written to `terminal.conf`; the app reads them
directly. `newTabDirectory` is applied by the coordinator when it creates a tab's first surface.

Values are escaped and validated by the generator; font families and theme names are only
accepted from the lists the UI offers. A unit test checks that `keybind = clear` is the first
line and that every field maps to the expected line.

**Runtime.** `GhosttyRuntime.loadConfig` changes to: `ghostty_config_new`,
`ghostty_config_load_file(cfg, terminalConfPath)`, `ghostty_config_finalize`. The calls to
`ghostty_config_load_default_files` and `ghostty_config_load_recursive_files` are removed.
On any settings change the app regenerates `terminal.conf` and calls the existing
`reloadConfig()`, which applies to all surfaces live. "Open config" actions are removed; the
banner action becomes "Open Settings".

**Migration** (first launch with no `settings.json`): copy `tabLayout` from `session.json` and
`tabListHidden` from `UserDefaults`, then remove the `UserDefaults` key. Everything else starts
at defaults.

**Settings window.** One `NSWindow` hosting a SwiftUI `SettingsView`, opened from
PrompTTY › Settings… (⌘,), reused if already open. System Settings style: a sidebar list of
sections and grouped `Form`s (`.formStyle(.grouped)`).

- **Appearance:** font family picker (installed monospaced families, enumerated with Core Text
  and filtered by the monospace trait); font size stepper (also ⌘+ / ⌘− / ⌘0 in terminals);
  "Match system appearance" toggle with light and dark theme pickers, or a single theme picker;
  cursor style and blink; tint strength slider. Theme pickers list the bundled
  `GhosttyKitResources/ghostty/themes` files, each row with a swatch strip (background,
  foreground, palette 1–6) parsed from the theme file.
- **Tabs & windows:** layout segmented control, sidebar width slider, new-tab directory,
  restore session, confirm close.
- **Keyboard:** section 5.

**SF Mono availability (risk).** macOS includes SF Mono but may not expose it to font lookup
by family name. Implementation verifies first whether `font-family = SF Mono` resolves in
libghostty. If it does not, the app registers the system's SF Mono font files for its own
process at launch (`CTFontManagerRegisterFontsForURL` with `.process` scope) before creating
the Ghostty app. The fonts are not copied into the bundle.

## 5. Keyboard

**Routing rule.** libghostty binds nothing (`keybind = clear`). PrompTTY's shortcuts are menu
key equivalents and every one contains ⌘. `TerminalSurfaceView` sends every key event without
⌘ straight to libghostty; events with ⌘ go through `performKeyEquivalent` to the menu first and
fall through to libghostty only if no menu item claims them. No Ctrl, Option, or Ctrl+Shift
combination is ever intercepted.

**Terminal actions** from the menu call `ghostty_surface_binding_action` on the focused pane:
`copy_to_clipboard`, `paste_from_clipboard`, `select_all`, `increase_font_size:1`,
`decrease_font_size:1`, `reset_font_size`, `clear_screen`. Font size changes from the menu also
update `fontSize` in settings so they persist.

**Default shortcuts** (defined in `Preferences` as `ShortcutMap.defaults`):

| Group | Action | Shortcut |
|---|---|---|
| Window | New Window | ⌘N |
| | Close Window | ⇧⌘W |
| Tabs | New Tab | ⌘T |
| | Close Tab | ⌥⌘W |
| | Next Tab / Previous Tab | ⇧⌘] / ⇧⌘[ |
| | Go to Tab 1–9 | ⌘1 … ⌘9 |
| | Toggle Sidebar | ⌘B |
| | Toggle Tab Layout | ⌃⌘S |
| Panes | Split Right / Split Down | ⌘D / ⇧⌘D |
| | Close Pane | ⌘W |
| | Focus Pane Left/Up/Right/Down | ⌥⌘← / ⌥⌘↑ / ⌥⌘→ / ⌥⌘↓ |
| | Equalize Panes | ⌃⌘= |
| Terminal | Copy / Paste / Select All | ⌘C / ⌘V / ⌘A |
| | Clear | ⌘K |
| | Bigger / Smaller / Actual Size | ⌘+ / ⌘− / ⌘0 |

Fixed and not editable: Quit ⌘Q, Hide ⌘H, Minimize ⌘M, Settings ⌘,.

**Shortcut editor** (Settings › Keyboard): an "Option key acts as Alt" picker (Both, Left only,
Right only, Off) and a table of the actions above, grouped, each with a recorder.

- The recorder accepts only shortcuts that include ⌘, and rejects the fixed shortcuts above.
- If the shortcut is used by another action, an inline message names it and offers "Swap".
- "Restore Defaults" clears all overrides.
- Changes save to `settings.json` and rebuild the menu's key equivalents immediately.

`MainMenu` is rebuilt from `ShortcutMap` (defaults merged with overrides) rather than
hard-coded key equivalents.

## Project layout changes

```
Sources/
  Preferences/            Settings, SettingsStore, TerminalConfigWriter, ShortcutMap, ThemeCatalog
  WorkspaceModel/         + Pane.swift, SplitNode.swift; Tab, WindowState, SessionSnapshot updated
  GhosttyBridge/          GhosttyRuntime (config path), TerminalSurfaceView (binding actions, inherited config)
  PrompTTYApp/
    Chrome/               WindowRootView, SidebarView, TabStripView, TabRow, PaneTreeView, PaneCard,
                          PaneHost, SplitDivider, BannerView, ExitedOverlay, ChromeTint
    Settings/             SettingsWindowController, SettingsView, AppearanceSection,
                          TabsSection, KeyboardSection, ShortcutRecorder, ThemeSwatch
    TerminalWindowController.swift, WorkspaceCoordinator.swift, MainMenu.swift, AppDelegate.swift
Tests/
  PreferencesTests/       settings round trip, .bak recovery, migration, terminal.conf output,
                          shortcut parsing, conflicts, ⌘ rule, theme file parsing
  WorkspaceModelTests/    + SplitNodeTests, pane moves between tabs, snapshot of focused pane
```

Removed: `ChromeView.swift`, `TabCollectionView.swift`, `TabItem.swift`,
`TerminalContainerView.swift` (replaced by the SwiftUI views above).

## Error handling

| Failure | Behavior |
|---|---|
| `settings.json` unreadable or invalid | keep it as `.bak`, use defaults, banner "Settings were reset" |
| libghostty reports diagnostics for `terminal.conf` | banner with the first message and "Reset to Defaults" |
| Selected font family missing (uninstalled) | libghostty falls back; Settings shows the family as "(missing)" |
| Selected theme file missing | fall back to Flexoki for that appearance, banner explains |
| Split creation fails (`ghostty_surface_new` returns nil) | remove the new pane, keep the old one, transient banner |
| Drop target disappeared mid-drag (tab or window closed) | drop is ignored |

## Testing

- **Unit:** `SplitNode` operations (split in every direction, remove including the root, neighbor
  lookup in nested layouts, ratio clamping, equalize, insert on every edge, leaf order);
  `WindowState.movePane` within and across tabs, including emptying the source tab;
  snapshot writes the focused pane; everything listed under `PreferencesTests`.
- **Bridge:** existing `GhosttyActionTests` updated for pane tokens.
- **Manual acceptance:**
  1. Fresh launch with no settings: Flexoki follows the system appearance; switching
     appearance changes theme and backdrop live.
  2. Font is SF Mono 13 (verify in the terminal, not just Settings).
  3. ⌘D and ⇧⌘D twice each; ⌥⌘ arrows move focus correctly; drag dividers; double-click a gap;
     ⌃⌘=.
  4. Drag a pane to each edge of another pane, onto another tab in the sidebar and strip, and
     into a second window; the shell in the moved pane keeps running (`top` stays live).
  5. ⌘W through panes until the tab closes; ⌥⌘W on a split tab; running-process confirmation.
  6. In Neovim, `Ctrl-V` then `<C-i>`, `<Tab>`, `<M-j>`, `<C-S-x>`: each arrives distinctly.
  7. Rebind Split Right to ⌥⌘D, confirm the menu updates and the old shortcut is free; try a
     shortcut without ⌘ and see it rejected; Restore Defaults.
  8. Change font, size, theme, cursor in Settings; all open panes update without restart.
  9. Quit with splits open, relaunch: tabs return as single panes in the focused pane's
     directory.
  10. Reduce Motion and Reduce Transparency on: no animations, opaque surfaces, still legible.
