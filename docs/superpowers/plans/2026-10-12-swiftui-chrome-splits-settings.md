# SwiftUI Chrome, Splits, and Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> Execution for this plan: native (superpowers:executing-plans), by the session that wrote it,
> with a whole-branch review at the end. The user asked for autonomous implementation.

**Goal:** Replace PrompTTY 2's AppKit chrome with SwiftUI + Liquid Glass, add splits and a Settings
window, and make PrompTTY's own settings the only config source with ⌘-only shortcuts.

**Architecture:** AppKit keeps the app lifecycle, menus and one `NSWindowController` per window; the
window's content and the Settings window are SwiftUI. A new `Preferences` library owns
`settings.json` and generates `terminal.conf` for libghostty. `WorkspaceModel` gains a pure
`SplitNode` tree; each pane owns one cached `TerminalSurfaceView` that SwiftUI only places.

**Tech Stack:** Swift 6.2+ (toolchain 6.4), SwiftUI + AppKit on macOS 26, libghostty via
`libghostty-spm` 0.2.0, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-12-swiftui-chrome-splits-settings-design.md`

## Global Constraints

- macOS 26 minimum: `platforms: [.macOS(.v26)]`, `MACOSX_DEPLOYMENT_TARGET: "26.0"`, `swift-tools-version: 6.2`.
- Swift 6 language mode, strict concurrency complete. UI and model types are `@MainActor`.
- Only `GhosttyBridge` imports `GhosttyKit`. `WorkspaceModel` and `Preferences` import Foundation only.
- `~/.config/ghostty/*` is never read. libghostty config comes only from `terminal.conf`.
- `terminal.conf` line 1 is exactly `keybind = clear`.
- Every PrompTTY shortcut contains ⌘. No Ctrl/Option/Ctrl+Shift combination without ⌘ is intercepted.
- Default theme `Flexoki Light` / `Flexoki Dark` following the system; default font `SF Mono` 13.
- Chrome text uses the system font; chrome icons are SF Symbols only.
- Splits are not restored; snapshot format stays version 1.
- No SwiftUI `.keyboardShortcut` on chrome controls (they would steal keys from the terminal).

## Review Focus

1. Ctrl combinations AppKit routes only through `performKeyEquivalent` (Ctrl+Return, Ctrl+/,
   Ctrl+Tab, Ctrl+.) must reach libghostty when a terminal is first responder → Task 5 adds the
   override and a routing-decision unit test (`KeyRouting`).
2. Dragging the only pane out of a tab, or dropping onto a pane that closed mid-drag, must not
   crash or leave an empty tab → Task 3 tests `movePane` emptying the source; Task 9 guards drops.
3. A `settings.json` from a newer version or with garbage must not block launch and must be kept
   as `.bak` → Task 4 tests both.
4. After rename, Settings close, or a pane close, keyboard focus must land on a terminal, never
   nowhere → Task 7/8 route every such path through `focusSelectedPane()`; acceptance step checks.
5. A theme or font name that no longer exists must fall back, not produce a libghostty diagnostic
   loop → Task 4 tests `TerminalConfigWriter` substitutes Flexoki for unknown themes.

---

### Task 0: Finish MVP Task 10 (session save/restore) and Task 11 test script

**Files:**
- Modify: `Sources/PrompTTYApp/AppDelegate.swift`
- Modify: `script/test`

- [ ] Restore at launch with `SessionStore(url: .defaultURL).load()` → `Workspace.restore(from:)`.
- [ ] `DebouncedSaver(delay: .seconds(1))` scheduled from `coordinator.onModelChanged`; flush + save in `applicationWillTerminate`.
- [ ] `applicationShouldTerminate` asks when `runtime.needsConfirmQuit`.
- [ ] `script/test` runs `swift test` then builds the app with xcodebuild `-quiet`.
- [ ] Build, run, quit, relaunch: tabs and layout restore. Commit `feat(app): restore tabs, directories, layout and window frames across launches`.

### Task 1: Platform bump to macOS 26

**Files:** `Package.swift`, `project.yml`

- [ ] `// swift-tools-version: 6.2`, `.macOS(.v26)`; project.yml deployment targets `"26.0"`.
- [ ] `swift test` and app build pass. Commit `chore: require macOS 26`.

### Task 2: `Pane` and `SplitNode`

**Files:**
- Create: `Sources/WorkspaceModel/Pane.swift`, `Sources/WorkspaceModel/SplitNode.swift`
- Test: `Tests/WorkspaceModelTests/SplitNodeTests.swift`

**Interfaces (produces):**

```swift
public struct PaneID: Hashable, Codable, Sendable { public let rawValue: UUID; public init(rawValue: UUID = UUID()) }
@MainActor @Observable public final class Pane {
    public let id: PaneID; public var title: String; public var workingDirectory: String
    public init(id: PaneID = PaneID(), title: String = "", workingDirectory: String)
}
public enum SplitAxis: String, Codable, Sendable { case horizontal, vertical }   // horizontal = side by side
public enum SplitDirection: Sendable { case left, right, up, down }               // also used for focus moves
public enum PaneEdge: Sendable { case left, right, top, bottom }
public struct SplitPath: Hashable, Sendable { public var steps: [Bool] }          // false = first, true = second
public indirect enum SplitNode: Equatable, Sendable {
    case leaf(PaneID)
    case split(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)
    public static let minRatio = 0.1, maxRatio = 0.9
    public var leaves: [PaneID]
    public func contains(_ pane: PaneID) -> Bool
    public func splitting(_ pane: PaneID, direction: SplitDirection, newPane: PaneID) -> SplitNode
    public func removing(_ pane: PaneID) -> SplitNode?
    public func inserting(_ pane: PaneID, at target: PaneID, edge: PaneEdge) -> SplitNode
    public func resizing(at path: SplitPath, ratio: Double) -> SplitNode
    public func equalized() -> SplitNode
    public func frames(in rect: CGRect) -> [PaneID: CGRect]
    public func neighbor(of pane: PaneID, direction: SplitDirection) -> PaneID?
}
```

- [ ] Write failing tests: split right/left/down/up produce correct axis/order and ratio 0.5;
  removing a leaf promotes its sibling; removing the root leaf returns nil; removing from nested
  keeps other ratios; `inserting` on every edge; ratio clamping in `resizing` (0.0→0.1, 1.0→0.9);
  `equalized`; `leaves` order; `frames` sum to the rect; `neighbor` in a 2×2 grid
  (right of top-left is top-right, down of top-right is bottom-right), in an L-shape picks the
  pane with most overlap, returns nil at edges; `splitting` a pane not in the tree returns self.
- [ ] Run `swift test --filter SplitNodeTests` → fails (types missing).
- [ ] Implement.
- [ ] Tests pass. Commit `feat(model): Pane and a pure SplitNode layout tree`.

### Task 3: Tab owns a split tree; moving panes; snapshot from focused pane

**Files:**
- Modify: `Sources/WorkspaceModel/Tab.swift`, `WindowState.swift`, `SessionSnapshot.swift`, `Workspace.swift`
- Test: `Tests/WorkspaceModelTests/TabTests.swift`, `WindowStateTests.swift`, `SessionSnapshotTests.swift`, new `PaneMoveTests.swift`

**Interfaces (produces):**

```swift
// Tab
public private(set) var root: SplitNode
public private(set) var panes: [PaneID: Pane]
public var focusedPaneID: PaneID
public var focusedPane: Pane
public var title: String { get }               // focused pane's title
public var workingDirectory: String { get }    // focused pane's directory
public var hasSplits: Bool
public init(id: TabID = TabID(), title: String, customTitle: String? = nil, workingDirectory: String, paneID: PaneID = PaneID())
@discardableResult public func split(_ pane: PaneID, direction: SplitDirection, workingDirectory: String) -> Pane
@discardableResult public func closePane(_ pane: PaneID) -> Bool   // false when it was the last pane (caller closes tab)
public func focus(_ pane: PaneID)
@discardableResult public func moveFocus(_ direction: SplitDirection) -> Bool
public func setRatio(at path: SplitPath, _ ratio: Double)
public func equalize()
public func detach(_ pane: PaneID) -> Pane?          // removes without closing, nil if last pane
public func attach(_ pane: Pane, at target: PaneID, edge: PaneEdge)
public func pane(_ id: PaneID) -> Pane?
// WindowState
public func tab(containing pane: PaneID) -> Tab?
// Workspace
public func tab(containing pane: PaneID) -> (WindowState, Tab)?
/// Moves `pane` next to `target` (same or other tab/window). Removes the source tab when emptied.
/// Returns false and changes nothing if pane == target or either is unknown.
@discardableResult public func movePane(_ pane: PaneID, to target: PaneID, edge: PaneEdge) -> Bool
/// Moves `pane` into `tab` next to its focused pane (right edge) and selects that tab.
@discardableResult public func movePane(_ pane: PaneID, intoTab tab: TabID) -> Bool
```

Existing `Tab.title`/`workingDirectory` setters disappear; callers write `tab.focusedPane.title` or
`tab.pane(id)?.title`. Existing tests that set `tab.title` are updated to set the pane.

- [ ] Write failing tests: new tab has one pane, focused; `split` focuses the new pane and
  `title`/`workingDirectory` follow focus; `closePane` refocuses the sibling side's first leaf and
  returns false for the last pane; `moveFocus` uses geometry; `movePane` within a tab, across tabs
  (target tab gains pane, source loses it), across windows, from a single-pane tab (source tab
  removed, target tab selected), to itself (false, unchanged); `movePane(intoTab:)` selects the tab;
  snapshot of a split tab writes the focused pane's title and directory.
- [ ] Run, see failures. Implement. Update existing tests and app call sites
  (`WorkspaceCoordinator` `.setTitle`/`.pwd` now write the pane) so everything compiles.
- [ ] `swift test` passes; app builds. Commit `feat(model): tabs own a split tree; move panes between tabs and windows`.

### Task 4: `Preferences` library

**Files:**
- Modify: `Package.swift` (library + test target)
- Create: `Sources/Preferences/Settings.swift`, `SettingsStore.swift`, `TerminalConfigWriter.swift`,
  `Shortcut.swift`, `ShortcutMap.swift`, `ThemeCatalog.swift`, `SettingsModel.swift`
- Test: `Tests/PreferencesTests/*`

**Interfaces (produces):**

```swift
public enum CursorStyle: String, Codable, CaseIterable, Sendable { case block, bar, underline }
public enum OptionAsAlt: String, Codable, CaseIterable, Sendable { case both, left, right, off }
public enum NewTabDirectory: String, Codable, CaseIterable, Sendable { case currentPane, home }
public enum TabLayoutSetting: String, Codable, Sendable { case sidebar, strip }   // mirrors WorkspaceModel.TabLayout; app maps
public struct Settings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = 1
    public var fontFamily = "SF Mono"; public var fontSize: Double = 13
    public var followSystemAppearance = true
    public var lightTheme = "Flexoki Light"; public var darkTheme = "Flexoki Dark"; public var theme = "Flexoki Dark"
    public var cursorStyle = CursorStyle.block; public var cursorBlink = true
    public var tintStrength: Double = 0.5
    public var tabLayout = TabLayoutSetting.sidebar; public var sidebarWidth: Double = 220; public var tabListHidden = false
    public var newTabDirectory = NewTabDirectory.currentPane; public var restoreSession = true; public var confirmCloseRunning = true
    public var optionAsAlt = OptionAsAlt.both
    public var shortcuts: [String: Shortcut] = [:]      // ShortcutAction.rawValue → override
    // decoding tolerates missing keys (each falls back to its default); clamps fontSize 6...72, sidebarWidth 180...320, tintStrength 0...1
}
public struct SettingsStore: Sendable {
    public let url: URL; public static var defaultURL: URL   // …/Application Support/PrompTTY/settings.json
    public enum LoadResult: Equatable { case missing, loaded(Settings), recovered }   // recovered = bad file moved to .bak, use defaults
    public func load() -> LoadResult
    public func save(_ settings: Settings) throws
}
public struct Shortcut: Codable, Hashable, Sendable {
    public var key: String              // lowercase character ("d", "[", "=") or named key ("left", "right", "up", "down", "return", "tab", "delete", "escape")
    public var modifiers: Modifiers     // OptionSet: command, shift, option, control
    public init?(string: String)        // "cmd+shift+d", "ctrl+cmd+="
    public var string: String           // canonical: ctrl+opt+shift+cmd+<key>
    public var displayString: String    // "⌃⌥⇧⌘D", "⌥⌘←"
    public var containsCommand: Bool
}
public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case newWindow, closeWindow, newTab, closeTab, nextTab, previousTab,
         gotoTab1, gotoTab2, gotoTab3, gotoTab4, gotoTab5, gotoTab6, gotoTab7, gotoTab8, gotoTab9,
         toggleSidebar, toggleTabLayout, splitRight, splitDown, closePane,
         focusPaneLeft, focusPaneUp, focusPaneRight, focusPaneDown, equalizePanes,
         copy, paste, selectAll, clear, biggerFont, smallerFont, actualSizeFont
    public var title: String; public var group: ShortcutGroup
}
public enum ShortcutGroup: String, CaseIterable, Sendable { case window, tabs, panes, terminal }
public struct ShortcutMap: Equatable, Sendable {
    public static let defaults: [ShortcutAction: Shortcut]
    public static let reserved: Set<Shortcut>      // ⌘Q ⌘H ⌘M ⌘,
    public init(overrides: [String: Shortcut])
    public func shortcut(for action: ShortcutAction) -> Shortcut
    public enum ValidationError: Error, Equatable { case missingCommand, reserved, conflict(ShortcutAction) }
    public func validate(_ shortcut: Shortcut, for action: ShortcutAction) -> ValidationError?
    public func assigning(_ shortcut: Shortcut, to action: ShortcutAction, swap: Bool) -> ShortcutMap   // swap gives the old owner this action's previous shortcut
    public var overrides: [String: Shortcut]       // only entries that differ from defaults
}
public struct ThemeSwatch: Equatable, Sendable { public var background: RGB; public var foreground: RGB; public var palette: [RGB] }
public struct RGB: Equatable, Sendable { public var r, g, b: UInt8; public init?(hex: String) }
public struct ThemeCatalog: Sendable {
    public init(directory: URL)
    public var names: [String]                       // sorted, case-insensitive
    public func contains(_ name: String) -> Bool
    public func swatch(for name: String) -> ThemeSwatch?
    public static func parse(_ contents: String) -> ThemeSwatch?
}
public enum TerminalConfigWriter {
    /// `knownThemes` / `knownFonts` nil means "don't validate".
    public static func render(_ settings: Settings, knownThemes: Set<String>?) -> String
}
@MainActor @Observable public final class SettingsModel {
    public var settings: Settings      // didSet → onChange
    public var onChange: ((Settings) -> Void)?
    public init(settings: Settings)
}
```

Migration helper (in `SettingsStore` file): `public static func migrated(tabLayout: TabLayoutSetting?, tabListHidden: Bool) -> Settings`.

- [ ] Failing tests: settings JSON round trip; decoding `{}` gives defaults; clamping; store
  missing / loaded / garbage → `.recovered` and `.bak` exists / `version: 99` → `.recovered`;
  `Shortcut(string:)` parsing incl. canonical order and invalid strings; display strings for
  arrows and brackets; defaults contain every action and all contain ⌘; validation: no ⌘ →
  `.missingCommand`, ⌘Q → `.reserved`, ⌘T for splitRight → `.conflict(.newTab)`; `assigning`
  with swap exchanges, without swap clears the other; `overrides` omits defaults; theme `parse`
  of the Flexoki Dark file contents; catalog lists names sorted; writer: line 1 is
  `keybind = clear`, theme line `theme = light:Flexoki Light,dark:Flexoki Dark`, single theme
  when not following, unknown theme → Flexoki fallback, option-as-alt mapping
  (both→true, left→left, right→right, off→false), font family quoting of names with spaces is
  not needed by Ghostty but newlines/`=` in values are stripped.
- [ ] Implement; tests pass. Commit `feat(prefs): settings file, terminal config generation, shortcuts and themes`.

### Task 5: Bridge: config path, binding actions, split context, key routing

**Files:**
- Modify: `Sources/GhosttyBridge/GhosttyRuntime.swift`, `TerminalSurfaceView.swift`, `TerminalSurfaceView+Input.swift`, `InputTranslation.swift`
- Test: `Tests/GhosttyBridgeTests/InputTranslationTests.swift` (KeyRouting)

**Interfaces (produces):**

```swift
// GhosttyRuntime
public init(configURL: URL) throws          // loads only this file
public var configURL: URL
public func reloadConfig()                  // re-reads configURL
// TerminalSurfaceView
public init(runtime: GhosttyRuntime, configuration: TerminalSurfaceConfiguration)
public struct TerminalSurfaceConfiguration { public var workingDirectory: String?; public var inheritFrom: TerminalSurfaceView? }
@discardableResult public func performBindingAction(_ action: String) -> Bool
public var hasSelection: Bool
public var onFocus: (() -> Void)?            // fired from becomeFirstResponder when it succeeds
// InputTranslation
public enum KeyRouting { public static func terminalHandlesKeyEquivalent(flags: NSEvent.ModifierFlags) -> Bool }  // true when no ⌘
```

- `inheritFrom` set → `ghostty_surface_inherited_config(source, GHOSTTY_SURFACE_CONTEXT_SPLIT)` as
  the base config, then platform/userdata/scale set on top; `workingDirectory` overrides when non-nil.
- `performKeyEquivalent(with:)`: if `window?.firstResponder === self`, event is keyDown, and
  `KeyRouting.terminalHandlesKeyEquivalent` → call `keyDown(with:)` and return true; else `false`.
- `openConfig()` removed from runtime (no Ghostty config to open); `.openConfig` action returns false.
- Remove `configuredBackground` use of Ghostty files? No: it reads from the loaded config, still valid.

- [ ] Failing test for `KeyRouting` (control-only → true, cmd → false, cmd+ctrl → false, none → true, option → true).
- [ ] Implement; tests pass; app compiles after updating `AppDelegate` to pass a config URL
  (temporary: write `keybind = clear` to a temp file until Task 6). Commit
  `feat(bridge): load config from a path, binding actions, split inheritance, ⌘-less keys reach the terminal`.

### Task 6: Wire preferences into the app

**Files:**
- Modify: `AppDelegate.swift`, `MainMenu.swift`, `WorkspaceCoordinator.swift`, `project.yml` (Preferences product)
- Create: `Sources/PrompTTYApp/FontRegistration.swift`, `Sources/PrompTTYApp/MenuActions.swift`

- Launch order: load settings (migrate on `.missing`, banner on `.recovered`) → register SF Mono if
  needed → write `terminal.conf` → `GhosttyRuntime(configURL:)` → restore session if
  `restoreSession`.
- `SettingsModel.onChange` → debounced save of `settings.json`, regenerate `terminal.conf`,
  `runtime.reloadConfig()` if the conf text changed, rebuild menu if shortcuts changed, re-apply
  layout/width/tint to windows.
- `FontRegistration.ensureSFMono()`: if `NSFontManager.shared.availableMembers(ofFontFamily: "SF Mono")`
  is nil, register `.otf`/`.ttf` files from `/System/Library/Fonts/` matching `SFNSMono*`/`SF-Mono*`
  and `/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts/SF-Mono-*.otf` with
  `CTFontManagerRegisterFontsForURL(url, .process, nil)`. Verify by the terminal actually rendering SF Mono.
- `MainMenu.build(shortcuts: ShortcutMap)`: every editable item takes its key equivalent from the map;
  terminal items target `TerminalWindowController` actions that call `performBindingAction` on the
  focused pane; Edit menu Copy/Paste/Select All go through the responder chain so text fields still work
  (the controller implements `copy(_:)`/`paste(_:)`/`selectAll(_:)` only when a terminal is first responder).
- App menu: About, Settings… ⌘, (opens settings window, Task 10 — until then a no-op), Hide, Hide Others, Show All, Quit.
- Remove Reload/Open Configuration items.
- Tab layout and hidden state read from settings; `Workspace.tabLayout` is set from settings at launch and kept in sync.

- [ ] Build; run; confirm Flexoki and SF Mono render, ⌘-less keys reach the shell (`cat -v`, then
  Ctrl+Return / Ctrl+/ show `^M`-family / `^_`), changing `settings.json` by hand and relaunching applies.
  Commit `feat(app): PrompTTY settings drive the terminal config and menu shortcuts`.

### Task 7: SwiftUI chrome (single pane per tab)

**Files:**
- Create in `Sources/PrompTTYApp/Chrome/`: `WindowChromeModel.swift` (per-window observable: tint, banner, exited panes, renaming tab),
  `WindowRootView.swift`, `SidebarView.swift`, `TabStripView.swift`, `TabRow.swift`, `PaneTreeView.swift`,
  `PaneCard.swift`, `PaneHost.swift`, `BannerView.swift` (SwiftUI, replaces AppKit), `ExitedOverlay.swift`, `ChromeMetrics.swift`
- Modify: `TerminalWindowController.swift` (NSHostingView root; surfaces keyed by PaneID), `WorkspaceCoordinator.swift`, `ChromeTint.swift` (SwiftUI Color + strength)
- Delete: `ChromeView.swift`, `TabCollectionView.swift`, `TabItem.swift`, `TerminalContainerView.swift`

- `PaneHost: NSViewRepresentable` → `PaneHostView: NSView` (rounded, masksToBounds, 12pt continuous)
  installs `controller.surfaceView(for: pane)`; when the view moves away it is removed from the old
  host by AppKit (an NSView has one superview). Occlusion: surfaces of non-selected tabs are
  removed from hosts and `setOccluded(true)`.
- Focus: `controller.focusSelectedPane()` makes the selected tab's focused pane first responder; called
  after selection changes, after rename ends, after pane close, after the Settings window closes.
- Sidebar header and strip leave room for traffic lights (78×38pt).
- Rename: double-click `TabRow` → `TextField` with `@FocusState`; Return/blur commits, Escape cancels.
- Reorder: `.draggable(TabDragItem)` + `.dropDestination` on rows computing the insert index.

- [ ] Build; run; verify sidebar/strip parity with the MVP (select, close, rename, reorder, +, ⌘B, ⌃⌘S),
  banner, exited overlay, tint, rounded card, resize. Commit `feat(chrome): SwiftUI window chrome with Liquid Glass`.

### Task 8: Splits in the app

**Files:** `TerminalWindowController.swift`, `WorkspaceCoordinator.swift`, `PaneTreeView.swift`, `PaneCard.swift`, create `SplitDivider.swift`

- Menu/header actions: splitRight/splitDown → `coordinator.split(direction)`; closePane → focused
  surface `requestClose()`; closeTab → confirm if any pane needs confirm, then close all;
  focusPane* → `tab.moveFocus`; equalizePanes → `tab.equalize()`.
- `closeSurface` / `showChildExited` / `onSurfaceCreationFailed` resolve the pane; closing the last pane closes the tab.
- `PaneTreeView` lays out `.split` with `GeometryReader`: first child gets `ratio × (length − 6)`;
  `SplitDivider` 6pt hit area with resize cursor; drag updates ratio live; double-click equalizes
  that split only.
- Focused pane: 1.5pt accent stroke; unfocused: backdrop overlay at 0.15 opacity (allowsHitTesting false).
- Surface `onFocus` → `tab.focus(pane)` so clicking a pane focuses it in the model.

- [ ] Build; run; acceptance steps 3 and 5 from the spec. Commit `feat(app): splits with focus navigation, resizable dividers and per-pane close`.

### Task 9: Drag panes to rearrange

**Files:** `PaneCard.swift`, `PaneTreeView.swift`, `TabRow.swift`, `WorkspaceCoordinator.swift`, create `PaneDragItem.swift`

- `PaneDragItem: Transferable, Codable` with `paneID` (UUID), exported as a custom UTType declared in
  Info.plist (`dev.promptty.pane`) via `CodableRepresentation(contentType:)`.
- Drag starts only from the header handle (`.draggable` on the handle).
- `PaneCard` `.dropDestination(for: PaneDragItem.self)` + `isTargeted`/location → edge highlight
  (nearest edge by normalized distance); drop → `coordinator.movePane(_, to:, edge:)`.
- `TabRow` drop → `coordinator.movePane(_, intoTab:)`.
- Coordinator moves the `TerminalSurfaceView` between controllers' `surfaces` dicts when windows differ,
  closes the source window if its last tab was removed, then reloads both windows and focuses the moved pane.
- Unknown pane IDs (closed mid-drag) → ignored.

- [ ] Build; run; acceptance step 4. Commit `feat(app): drag panes between splits, tabs and windows`.

### Task 10: Settings window

**Files:** create `Sources/PrompTTYApp/Settings/SettingsWindowController.swift`, `SettingsView.swift`,
`AppearanceSection.swift`, `TabsSection.swift`, `KeyboardSection.swift`, `ShortcutRecorder.swift`, `ThemePicker.swift`, `MonospacedFonts.swift`

- One reusable `NSWindow` (titled, closable, 680×520, `NSHostingController(SettingsView)`), opened by ⌘,.
- `SettingsView`: `NavigationSplitView` with sections list (SF Symbols `textformat`, `rectangle.split.3x1`, `keyboard`) and grouped `Form`s.
- `MonospacedFonts.families()` via `NSFontManager.availableFontFamilies` filtered by `.fixedPitch` trait of the regular member, plus `SF Mono`.
- `ThemePicker`: searchable list of `ThemeCatalog.names` with a swatch strip per row.
- `ShortcutRecorder`: an `NSViewRepresentable` key-capturing view; on keyDown builds `Shortcut`, validates
  via `ShortcutMap.validate`, shows inline error / "Swap" button; Escape cancels; Delete restores default.
- On window close → `focusSelectedPane()` in the key terminal window.

- [ ] Build; run; acceptance steps 7, 8. Commit `feat(settings): Settings window for appearance, tabs and keyboard`.

### Task 11: README and acceptance pass

- [ ] README updated (macOS 26, settings, shortcuts table, no Ghostty config).
- [ ] Run the spec's 10-step manual acceptance with screenshots; fix failures; record results in the commit body.
- [ ] Whole-branch review by a fresh reviewer; address findings. Commit `docs: README for SwiftUI chrome, splits and settings`.
