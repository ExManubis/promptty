# PrompTTY 2 MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS terminal app on libghostty with tabs shown either in a vertical sidebar or a horizontal strip, Arc/Dia-styled chrome, reading the user's Ghostty config, restoring tabs and working directories on relaunch.

**Architecture:** Four Swift targets. `WorkspaceModel` (pure Foundation, `@Observable` classes for Workspace → WindowState → Tab plus JSON session persistence). `GhosttyBridge` (the only target importing `GhosttyKit`: owns `ghostty_app_t`, the six C callbacks, a typed `GhosttyAction` enum, and `TerminalSurfaceView`). `PrompTTYApp` (AppKit chrome: window controller, tab list, terminal card, menus, and a `WorkspaceCoordinator` that is the bridge's action sink). Tests for the two libraries.

**Tech Stack:** Swift 6 (strict concurrency), AppKit, SwiftPM for libraries, XcodeGen for the app project, libghostty via `sethdeckard/libghostty-spm` v0.2.0 (`GhosttyKit` xcframework + `GhosttyKitResources`), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-04-promptty2-mvp-design.md`

**Deviation from spec, agreed here:** the spec asks for callback dispatch tests through a fake sink. `GhosttyRuntime` calls `ghostty_init` in-process, which is unsafe inside XCTest, so dispatch is covered by the manual acceptance list (Task 11) while decoding (Task 4) and input translation (Task 6) are unit-tested.

## Global Constraints

- Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY=complete`. No SwiftUI in the chrome or the terminal host.
- Minimum macOS 15.0.
- libghostty only through `GhosttyKit` from `https://github.com/sethdeckard/libghostty-spm`, pinned `exact: "0.2.0"`. No Zig in the default build.
- Only the `GhosttyBridge` target may `import GhosttyKit` or `GhosttyKitResources`. No `ghostty_*` symbol or C type appears in a public signature of `GhosttyBridge`.
- One process. libghostty spawns and owns the shell. `command` in the surface config stays unset.
- Read `~/.config/ghostty/config` via `ghostty_config_load_default_files`; never write to it.
- `action_cb` returns `false` for every action the app does not implement.
- Session state at `~/Library/Application Support/PrompTTY/session.json`; preferences in `UserDefaults`. Scrollback is not persisted.
- No blocking alerts for config errors or surface failures; use the banner.
- Out of scope: splits, tab groups, pinned tabs, command bar, agent integration, daemon, Sparkle, notarization.
- Commit messages: conventional prefix (`feat:`, `test:`, `chore:`, `docs:`), no attribution trailers.

## Review Focus

Inputs the spec implies but did not call out, each pinned to a test in the owning task:

1. Closing the last tab in a window must close the window, not leave empty chrome. (Task 2: `WindowState.closeTab` reports `isEmpty`; Task 9 coordinator closes the window.)
2. A corrupt or future-format `session.json` must not prevent launch: rename it to `.bak`, start with one tab in `$HOME`. (Task 3: `SessionStore.load` test.)
3. A restored tab whose working directory no longer exists must fall back to `$HOME` instead of a dead surface. (Task 3: `Workspace.restore(from:directoryExists:)` test.)
4. `goto_tab` with an index beyond the tab count, or `move_tab` past the ends, must return `false` and leave order unchanged. (Task 2: `gotoTab` / `moveSelectedTab` tests.)
5. Shell-supplied titles with control characters or thousands of characters must render as one sane line in the tab row. (Task 2: `Tab.displayTitle` sanitization test.)

---

## File structure

```
promptty-2/
  Package.swift
  project.yml
  .gitignore
  script/bootstrap        install xcodegen, resolve packages, generate project
  script/run              build the app with xcodebuild and open it
  script/test             swift test
  Sources/
    WorkspaceModel/
      TabLayout.swift             enum TabLayout { sidebar, strip }
      Tab.swift                   Tab, TabID, title sanitization
      WindowState.swift           ordered tabs, selection, goto/move/close
      Workspace.swift             windows + layout, toggle
      SessionSnapshot.swift       Codable snapshot types + snapshot()/restore()
      SessionStore.swift          load/save JSON, .bak on corruption
      DebouncedSaver.swift        coalesce saves
    GhosttyBridge/
      GhosttyInfo.swift           version string (link smoke test)
      GhosttyAction.swift         Swift enum decoded from ghostty_action_s
      GhosttyActionSink.swift     protocol the app implements
      GhosttyRuntime.swift        ghostty_app_t owner, config, callbacks, tick
      TerminalSurfaceView.swift   NSView + CAMetalLayer, surface lifecycle
      TerminalSurfaceView+Input.swift  keyboard, IME, mouse
      InputTranslation.swift      NSEvent → ghostty mods/buttons/scroll (pure, tested)
    PrompTTYApp/
      AppDelegate.swift           runtime, workspace, coordinator, menus
      MainMenu.swift              NSMenu built in code
      WorkspaceCoordinator.swift  GhosttyActionSink; model ↔ windows ↔ surfaces
      Chrome/
        TerminalWindowController.swift
        ChromeView.swift          tint background, layout host
        ChromeTint.swift          background color → tint (pure, tested in model? no: app-only)
        TerminalContainerView.swift  rounded card, one surface per tab
        BannerView.swift          non-modal message strip
        TabCollectionView.swift   NSCollectionView, vertical or horizontal
        TabItem.swift             NSCollectionViewItem for both modes
  Tests/
    WorkspaceModelTests/
      TabLayoutTests.swift
      TabTests.swift
      WindowStateTests.swift
      WorkspaceTests.swift
      SessionSnapshotTests.swift
      SessionStoreTests.swift
      DebouncedSaverTests.swift
    GhosttyBridgeTests/
      GhosttyInfoTests.swift
      GhosttyActionTests.swift
      InputTranslationTests.swift
```

---

### Task 1: Project scaffold that links libghostty

**Files:**
- Create: `Package.swift`
- Create: `project.yml`
- Create: `.gitignore`
- Create: `script/bootstrap`, `script/run`, `script/test`
- Create: `Sources/WorkspaceModel/TabLayout.swift`
- Create: `Sources/GhosttyBridge/GhosttyInfo.swift`
- Create: `Sources/PrompTTYApp/AppDelegate.swift`
- Test: `Tests/WorkspaceModelTests/TabLayoutTests.swift`
- Test: `Tests/GhosttyBridgeTests/GhosttyInfoTests.swift`

**Interfaces:**
- Produces: `public enum TabLayout: String, Codable, Sendable { case sidebar, strip; public var toggled: TabLayout }`
- Produces: `public enum GhosttyInfo { public static var version: String }`

- [ ] **Step 1: Write the failing model test**

`Tests/WorkspaceModelTests/TabLayoutTests.swift`:

```swift
import XCTest
@testable import WorkspaceModel

final class TabLayoutTests: XCTestCase {
    func testToggleFlipsBetweenSidebarAndStrip() {
        XCTAssertEqual(TabLayout.sidebar.toggled, .strip)
        XCTAssertEqual(TabLayout.strip.toggled, .sidebar)
    }

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(TabLayout.sidebar.rawValue, "sidebar")
        XCTAssertEqual(TabLayout.strip.rawValue, "strip")
    }
}
```

- [ ] **Step 2: Write the failing bridge test**

`Tests/GhosttyBridgeTests/GhosttyInfoTests.swift`:

```swift
import XCTest
@testable import GhosttyBridge

final class GhosttyInfoTests: XCTestCase {
    func testVersionStringIsNonEmpty() {
        XCTAssertFalse(GhosttyInfo.version.isEmpty)
    }
}
```

- [ ] **Step 3: Create Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrompTTY",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WorkspaceModel", targets: ["WorkspaceModel"]),
        .library(name: "GhosttyBridge", targets: ["GhosttyBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sethdeckard/libghostty-spm", exact: "0.2.0"),
    ],
    targets: [
        .target(name: "WorkspaceModel"),
        .target(
            name: "GhosttyBridge",
            dependencies: [
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "GhosttyKitResources", package: "libghostty-spm"),
            ]
        ),
        .testTarget(name: "WorkspaceModelTests", dependencies: ["WorkspaceModel"]),
        .testTarget(
            name: "GhosttyBridgeTests",
            dependencies: [
                "GhosttyBridge",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 4: Create the two library sources**

`Sources/WorkspaceModel/TabLayout.swift`:

```swift
/// Where the tab list lives in a window.
public enum TabLayout: String, Codable, Sendable {
    case sidebar
    case strip

    public var toggled: TabLayout {
        switch self {
        case .sidebar: return .strip
        case .strip: return .sidebar
        }
    }
}
```

`Sources/GhosttyBridge/GhosttyInfo.swift`:

```swift
import GhosttyKit

/// Build information from the linked libghostty. Exists mainly to prove linking works.
public enum GhosttyInfo {
    public static var version: String {
        let info = ghostty_info()
        guard let ptr = info.version else { return "" }
        let buffer = UnsafeBufferPointer(start: ptr, count: Int(info.version_len))
        return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
```

- [ ] **Step 5: Run the library tests**

Run: `swift test`
Expected: both test files PASS. The first run downloads `GhosttyKit.xcframework.zip` (~140 MB); if it fails with a checksum or network error, stop and report, do not change the pin.

- [ ] **Step 6: Create the app target via XcodeGen**

`project.yml`:

```yaml
name: PrompTTY
options:
  bundleIdPrefix: dev.promptty
  deploymentTarget:
    macOS: "15.0"
  createIntermediateGroups: true
packages:
  PrompTTYCore:
    path: .
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    MACOSX_DEPLOYMENT_TARGET: "15.0"
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Manual
    ENABLE_HARDENED_RUNTIME: NO
targets:
  PrompTTYApp:
    type: application
    platform: macOS
    sources:
      - path: Sources/PrompTTYApp
    dependencies:
      - package: PrompTTYCore
        product: WorkspaceModel
      - package: PrompTTYCore
        product: GhosttyBridge
    settings:
      base:
        PRODUCT_NAME: PrompTTY
        PRODUCT_BUNDLE_IDENTIFIER: dev.promptty.PrompTTY2
        INFOPLIST_KEY_NSPrincipalClass: NSApplication
        INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.developer-tools
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_NSHumanReadableCopyright: ""
schemes:
  PrompTTYApp:
    build:
      targets:
        PrompTTYApp: all
    run:
      config: Debug
```

`Sources/PrompTTYApp/AppDelegate.swift` (temporary minimal delegate; Task 7 replaces its body):

```swift
import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit PrompTTY", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem)
        NSApp.mainMenu = menu

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PrompTTY"
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

- [ ] **Step 7: Scripts and .gitignore**

`.gitignore`:

```
.build/
DerivedData/
*.xcodeproj
xcuserdata/
.DS_Store
```

`script/bootstrap`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || brew install xcodegen
swift package resolve
xcodegen generate
```

`script/run`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d PrompTTY.xcodeproj ] || xcodegen generate
xcodebuild -project PrompTTY.xcodeproj -scheme PrompTTYApp -configuration Debug \
  -derivedDataPath .build/DerivedData build | tail -5
open .build/DerivedData/Build/Products/Debug/PrompTTY.app
```

`script/test`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
```

Run: `chmod +x script/*`

- [ ] **Step 8: Build and launch the empty app**

Run: `./script/bootstrap && ./script/run`
Expected: `BUILD SUCCEEDED`, an empty window titled PrompTTY opens, ⌘Q quits. The `GhosttyKitResources` resource bundle is copied into the app transitively through `GhosttyBridge`; if xcodebuild reports it missing, add a third dependency entry `- package: PrompTTYCore` / `product: GhosttyKitResources` to the target and rebuild.

- [ ] **Step 9: Commit**

```bash
git add Package.swift project.yml .gitignore script Sources Tests
git commit -m "chore: scaffold SwiftPM libraries, XcodeGen app target, link libghostty"
```

---

### Task 2: WorkspaceModel core (Tab, WindowState, Workspace)

**Files:**
- Create: `Sources/WorkspaceModel/Tab.swift`
- Create: `Sources/WorkspaceModel/WindowState.swift`
- Create: `Sources/WorkspaceModel/Workspace.swift`
- Test: `Tests/WorkspaceModelTests/TabTests.swift`
- Test: `Tests/WorkspaceModelTests/WindowStateTests.swift`
- Test: `Tests/WorkspaceModelTests/WorkspaceTests.swift`

**Interfaces:**
- Produces:
  - `public struct TabID: Hashable, Codable, Sendable`
  - `@MainActor @Observable public final class Tab { let id: TabID; var title: String; var customTitle: String?; var workingDirectory: String; var displayTitle: String; var abbreviatedDirectory: String }`
  - `public struct WindowID: Hashable, Codable, Sendable`
  - `public struct WindowFrame: Codable, Equatable, Sendable { x, y, width, height: Double }`
  - `public enum GotoTabTarget: Equatable, Sendable { case index(Int) /* 1-based */, previous, next, last }`
  - `@MainActor @Observable public final class WindowState { let id: WindowID; var frame: WindowFrame?; private(set) var tabs: [Tab]; var selectedTabID: TabID?; var selectedTab: Tab?; var isEmpty: Bool; func addTab(title:workingDirectory:) -> Tab; func closeTab(id:) -> Tab?; func select(id:); func gotoTab(_:) -> Bool; func moveSelectedTab(by:) -> Bool; func tab(id:) -> Tab?; func index(of:) -> Int? }`
  - `@MainActor @Observable public final class Workspace { var tabLayout: TabLayout; private(set) var windows: [WindowState]; func toggleTabLayout(); func addWindow(frame:) -> WindowState; func removeWindow(id:); func window(id:) -> WindowState?; func window(containing tabID:) -> WindowState? }`

- [ ] **Step 1: Write failing Tab tests**

`Tests/WorkspaceModelTests/TabTests.swift`:

```swift
import XCTest
@testable import WorkspaceModel

@MainActor
final class TabTests: XCTestCase {
    func testDisplayTitlePrefersCustomTitle() {
        let tab = Tab(title: "zsh", workingDirectory: "/tmp")
        XCTAssertEqual(tab.displayTitle, "zsh")
        tab.customTitle = "build"
        XCTAssertEqual(tab.displayTitle, "build")
    }

    func testEmptyCustomTitleIsTreatedAsNone() {
        let tab = Tab(title: "zsh", workingDirectory: "/tmp")
        tab.customTitle = "   "
        XCTAssertEqual(tab.displayTitle, "zsh")
    }

    func testDisplayTitleStripsControlCharactersAndTruncates() {
        let nasty = "a\u{1B}[31mb\nc\u{07}" + String(repeating: "x", count: 500)
        let tab = Tab(title: nasty, workingDirectory: "/tmp")
        let shown = tab.displayTitle
        XCTAssertFalse(shown.contains("\u{1B}"))
        XCTAssertFalse(shown.contains("\n"))
        XCTAssertFalse(shown.contains("\u{07}"))
        XCTAssertLessThanOrEqual(shown.count, Tab.maxDisplayTitleLength)
        XCTAssertTrue(shown.hasPrefix("a[31mbc"))
    }

    func testBlankTitleFallsBackToShellPlaceholder() {
        let tab = Tab(title: "", workingDirectory: "/tmp")
        XCTAssertEqual(tab.displayTitle, "Terminal")
    }

    func testAbbreviatedDirectoryReplacesHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tab = Tab(title: "zsh", workingDirectory: home + "/Developer/x")
        XCTAssertEqual(tab.abbreviatedDirectory, "~/Developer/x")
        tab.workingDirectory = home
        XCTAssertEqual(tab.abbreviatedDirectory, "~")
        tab.workingDirectory = "/usr/local"
        XCTAssertEqual(tab.abbreviatedDirectory, "/usr/local")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TabTests`
Expected: compile error, `Tab` not found.

- [ ] **Step 3: Implement Tab**

`Sources/WorkspaceModel/Tab.swift`:

```swift
import Foundation
import Observation

public struct TabID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

@MainActor
@Observable
public final class Tab {
    public static let maxDisplayTitleLength = 80
    public static let fallbackTitle = "Terminal"

    public let id: TabID
    /// Title reported by the terminal (OSC 0/2 via Ghostty `set_title`).
    public var title: String
    /// User rename; blank means none.
    public var customTitle: String?
    /// Last working directory reported via OSC 7 (Ghostty `pwd`), or the launch directory.
    public var workingDirectory: String

    public init(id: TabID = TabID(), title: String, customTitle: String? = nil, workingDirectory: String) {
        self.id = id
        self.title = title
        self.customTitle = customTitle
        self.workingDirectory = workingDirectory
    }

    public var displayTitle: String {
        let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = custom.isEmpty ? title : custom
        let cleaned = Tab.sanitize(raw)
        return cleaned.isEmpty ? Tab.fallbackTitle : cleaned
    }

    public var abbreviatedDirectory: String {
        Tab.abbreviate(workingDirectory)
    }

    /// Removes C0/C1 controls and newlines, collapses whitespace, truncates.
    static func sanitize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(min(s.count, maxDisplayTitleLength))
        for scalar in s.unicodeScalars {
            if scalar.properties.generalCategory == .control { continue }
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { continue }
            out.unicodeScalars.append(scalar)
            if out.count >= maxDisplayTitleLength { break }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
```

- [ ] **Step 4: Run Tab tests**

Run: `swift test --filter TabTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Write failing WindowState tests**

`Tests/WorkspaceModelTests/WindowStateTests.swift`:

```swift
import XCTest
@testable import WorkspaceModel

@MainActor
final class WindowStateTests: XCTestCase {
    private func window(tabCount: Int) -> WindowState {
        let w = WindowState()
        for i in 0..<tabCount { _ = w.addTab(title: "t\(i)", workingDirectory: "/tmp/\(i)") }
        return w
    }

    func testNewWindowIsEmptyAndHasNoSelection() {
        let w = WindowState()
        XCTAssertTrue(w.isEmpty)
        XCTAssertNil(w.selectedTab)
    }

    func testAddTabInsertsAfterSelectionAndSelectsIt() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[0].id)
        let inserted = w.addTab(title: "new", workingDirectory: "/x")
        XCTAssertEqual(w.tabs.map(\.title), ["t0", "new", "t1", "t2"])
        XCTAssertEqual(w.selectedTabID, inserted.id)
    }

    func testCloseSelectedTabSelectsRightNeighborThenLeft() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[1].id)
        _ = w.closeTab(id: w.tabs[1].id)
        XCTAssertEqual(w.selectedTab?.title, "t2")
        _ = w.closeTab(id: w.tabs[1].id) // closes t2, nothing to the right
        XCTAssertEqual(w.selectedTab?.title, "t0")
    }

    func testCloseUnselectedTabKeepsSelection() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[2].id)
        _ = w.closeTab(id: w.tabs[0].id)
        XCTAssertEqual(w.selectedTab?.title, "t2")
    }

    func testCloseLastTabLeavesWindowEmpty() {
        let w = window(tabCount: 1)
        let closed = w.closeTab(id: w.tabs[0].id)
        XCTAssertNotNil(closed)
        XCTAssertTrue(w.isEmpty)
        XCTAssertNil(w.selectedTabID)
    }

    func testCloseUnknownTabReturnsNil() {
        let w = window(tabCount: 1)
        XCTAssertNil(w.closeTab(id: TabID()))
        XCTAssertEqual(w.tabs.count, 1)
    }

    func testGotoTabByOneBasedIndex() {
        let w = window(tabCount: 3)
        XCTAssertTrue(w.gotoTab(.index(1)))
        XCTAssertEqual(w.selectedTab?.title, "t0")
        XCTAssertTrue(w.gotoTab(.index(3)))
        XCTAssertEqual(w.selectedTab?.title, "t2")
    }

    func testGotoTabOutOfRangeReturnsFalseAndKeepsSelection() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[1].id)
        XCTAssertFalse(w.gotoTab(.index(0)))
        XCTAssertFalse(w.gotoTab(.index(4)))
        XCTAssertFalse(w.gotoTab(.index(-1)))
        XCTAssertEqual(w.selectedTab?.title, "t1")
    }

    func testGotoPreviousNextWrapAround() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[0].id)
        XCTAssertTrue(w.gotoTab(.previous))
        XCTAssertEqual(w.selectedTab?.title, "t2")
        XCTAssertTrue(w.gotoTab(.next))
        XCTAssertEqual(w.selectedTab?.title, "t0")
        XCTAssertTrue(w.gotoTab(.last))
        XCTAssertEqual(w.selectedTab?.title, "t2")
    }

    func testGotoOnSingleTabReturnsFalse() {
        let w = window(tabCount: 1)
        XCTAssertFalse(w.gotoTab(.next))
        XCTAssertFalse(w.gotoTab(.previous))
    }

    func testMoveSelectedTabClampsAtEnds() {
        let w = window(tabCount: 3)
        w.select(id: w.tabs[0].id)
        XCTAssertFalse(w.moveSelectedTab(by: -1))
        XCTAssertTrue(w.moveSelectedTab(by: 2))
        XCTAssertEqual(w.tabs.map(\.title), ["t1", "t2", "t0"])
        XCTAssertFalse(w.moveSelectedTab(by: 1))
        XCTAssertTrue(w.moveSelectedTab(by: -1))
        XCTAssertEqual(w.tabs.map(\.title), ["t1", "t0", "t2"])
        XCTAssertEqual(w.selectedTab?.title, "t0")
    }

    func testMoveTabToIndexReorders() {
        let w = window(tabCount: 3)
        w.moveTab(id: w.tabs[2].id, to: 0)
        XCTAssertEqual(w.tabs.map(\.title), ["t2", "t0", "t1"])
    }
}
```

- [ ] **Step 6: Run to verify failure**

Run: `swift test --filter WindowStateTests`
Expected: compile error, `WindowState` not found.

- [ ] **Step 7: Implement WindowState**

`Sources/WorkspaceModel/WindowState.swift`:

```swift
import Foundation
import Observation

public struct WindowID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum GotoTabTarget: Equatable, Sendable {
    /// 1-based, matching Ghostty's `goto_tab:N` keybind.
    case index(Int)
    case previous
    case next
    case last
}

@MainActor
@Observable
public final class WindowState {
    public let id: WindowID
    public var frame: WindowFrame?
    public private(set) var tabs: [Tab] = []
    public var selectedTabID: TabID?

    public init(id: WindowID = WindowID(), frame: WindowFrame? = nil) {
        self.id = id
        self.frame = frame
    }

    public var isEmpty: Bool { tabs.isEmpty }

    public var selectedTab: Tab? {
        guard let selectedTabID else { return nil }
        return tab(id: selectedTabID)
    }

    public func tab(id: TabID) -> Tab? { tabs.first { $0.id == id } }

    public func index(of id: TabID) -> Int? { tabs.firstIndex { $0.id == id } }

    @discardableResult
    public func addTab(title: String, workingDirectory: String, id: TabID = TabID(), customTitle: String? = nil) -> Tab {
        let tab = Tab(id: id, title: title, customTitle: customTitle, workingDirectory: workingDirectory)
        let insertAt: Int
        if let selectedTabID, let i = index(of: selectedTabID) {
            insertAt = i + 1
        } else {
            insertAt = tabs.count
        }
        tabs.insert(tab, at: insertAt)
        self.selectedTabID = tab.id
        return tab
    }

    /// Removes the tab and, if it was selected, selects the right neighbor, else the left.
    @discardableResult
    public func closeTab(id: TabID) -> Tab? {
        guard let i = index(of: id) else { return nil }
        let removed = tabs.remove(at: i)
        if selectedTabID == id {
            if tabs.isEmpty {
                selectedTabID = nil
            } else {
                let next = min(i, tabs.count - 1)
                selectedTabID = tabs[next].id
            }
        }
        return removed
    }

    public func select(id: TabID) {
        guard tab(id: id) != nil else { return }
        selectedTabID = id
    }

    @discardableResult
    public func gotoTab(_ target: GotoTabTarget) -> Bool {
        guard !tabs.isEmpty else { return false }
        let current = selectedTabID.flatMap(index(of:)) ?? 0
        let destination: Int
        switch target {
        case .index(let n):
            guard n >= 1, n <= tabs.count else { return false }
            destination = n - 1
        case .previous:
            guard tabs.count > 1 else { return false }
            destination = (current - 1 + tabs.count) % tabs.count
        case .next:
            guard tabs.count > 1 else { return false }
            destination = (current + 1) % tabs.count
        case .last:
            destination = tabs.count - 1
        }
        selectedTabID = tabs[destination].id
        return true
    }

    /// Moves the selected tab by `amount` positions; returns false if nothing moved.
    @discardableResult
    public func moveSelectedTab(by amount: Int) -> Bool {
        guard let selectedTabID, let from = index(of: selectedTabID) else { return false }
        let to = from + amount
        guard to >= 0, to < tabs.count, to != from else { return false }
        moveTab(id: selectedTabID, to: to)
        return true
    }

    public func moveTab(id: TabID, to newIndex: Int) {
        guard let from = index(of: id) else { return }
        let clamped = max(0, min(newIndex, tabs.count - 1))
        guard clamped != from else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: clamped)
    }
}
```

- [ ] **Step 8: Run WindowState tests**

Run: `swift test --filter WindowStateTests`
Expected: PASS (12 tests).

- [ ] **Step 9: Write failing Workspace tests**

`Tests/WorkspaceModelTests/WorkspaceTests.swift`:

```swift
import XCTest
@testable import WorkspaceModel

@MainActor
final class WorkspaceTests: XCTestCase {
    func testDefaultLayoutIsSidebarAndToggles() {
        let ws = Workspace()
        XCTAssertEqual(ws.tabLayout, .sidebar)
        ws.toggleTabLayout()
        XCTAssertEqual(ws.tabLayout, .strip)
    }

    func testAddAndRemoveWindows() {
        let ws = Workspace()
        let a = ws.addWindow()
        let b = ws.addWindow(frame: WindowFrame(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(ws.windows.map(\.id), [a.id, b.id])
        XCTAssertEqual(b.frame, WindowFrame(x: 1, y: 2, width: 3, height: 4))
        ws.removeWindow(id: a.id)
        XCTAssertEqual(ws.windows.map(\.id), [b.id])
        XCTAssertNil(ws.window(id: a.id))
    }

    func testWindowContainingTab() {
        let ws = Workspace()
        let a = ws.addWindow()
        let b = ws.addWindow()
        let tab = b.addTab(title: "x", workingDirectory: "/")
        XCTAssertEqual(ws.window(containing: tab.id)?.id, b.id)
        XCTAssertNil(ws.window(containing: TabID()))
        _ = a
    }
}
```

- [ ] **Step 10: Implement Workspace**

`Sources/WorkspaceModel/Workspace.swift`:

```swift
import Foundation
import Observation

@MainActor
@Observable
public final class Workspace {
    public var tabLayout: TabLayout
    public private(set) var windows: [WindowState] = []

    public init(tabLayout: TabLayout = .sidebar) {
        self.tabLayout = tabLayout
    }

    public func toggleTabLayout() { tabLayout = tabLayout.toggled }

    @discardableResult
    public func addWindow(id: WindowID = WindowID(), frame: WindowFrame? = nil) -> WindowState {
        let w = WindowState(id: id, frame: frame)
        windows.append(w)
        return w
    }

    public func removeWindow(id: WindowID) {
        windows.removeAll { $0.id == id }
    }

    public func window(id: WindowID) -> WindowState? { windows.first { $0.id == id } }

    public func window(containing tabID: TabID) -> WindowState? {
        windows.first { $0.tab(id: tabID) != nil }
    }
}
```

- [ ] **Step 11: Run all model tests**

Run: `swift test --filter WorkspaceModelTests`
Expected: PASS.

- [ ] **Step 12: Commit**

```bash
git add Sources/WorkspaceModel Tests/WorkspaceModelTests
git commit -m "feat(model): Tab, WindowState, Workspace with tab navigation semantics"
```

---

### Task 3: Session persistence

**Files:**
- Create: `Sources/WorkspaceModel/SessionSnapshot.swift`
- Create: `Sources/WorkspaceModel/SessionStore.swift`
- Create: `Sources/WorkspaceModel/DebouncedSaver.swift`
- Test: `Tests/WorkspaceModelTests/SessionSnapshotTests.swift`
- Test: `Tests/WorkspaceModelTests/SessionStoreTests.swift`
- Test: `Tests/WorkspaceModelTests/DebouncedSaverTests.swift`

**Interfaces:**
- Consumes: `Workspace`, `WindowState`, `Tab`, `TabLayout`, `WindowFrame` from Task 2.
- Produces:
  - `public struct SessionSnapshot: Codable, Equatable, Sendable { static let currentVersion = 1; var version: Int; var tabLayout: TabLayout; var windows: [WindowSnapshot] }`
  - `public struct WindowSnapshot: Codable, Equatable, Sendable { var frame: WindowFrame?; var tabs: [TabSnapshot]; var selectedIndex: Int? }`
  - `public struct TabSnapshot: Codable, Equatable, Sendable { var title: String; var customTitle: String?; var workingDirectory: String }`
  - `extension Workspace { func snapshot() -> SessionSnapshot; static func restore(from: SessionSnapshot, directoryExists: (String) -> Bool = ..., fallbackDirectory: String = NSHomeDirectory()) -> Workspace }`
  - `public struct SessionStore { init(url: URL); static var defaultURL: URL; func load() -> SessionSnapshot?; func save(_:) throws }`
  - `@MainActor public final class DebouncedSaver { init(delay: Duration, action: @escaping @MainActor () -> Void); func schedule(); func flush() }`

- [ ] **Step 1: Write failing snapshot tests**

`Tests/WorkspaceModelTests/SessionSnapshotTests.swift`:

```swift
import XCTest
@testable import WorkspaceModel

@MainActor
final class SessionSnapshotTests: XCTestCase {
    func testSnapshotCapturesLayoutWindowsTabsAndSelection() {
        let ws = Workspace(tabLayout: .strip)
        let w = ws.addWindow(frame: WindowFrame(x: 10, y: 20, width: 800, height: 600))
        _ = w.addTab(title: "a", workingDirectory: "/a")
        let b = w.addTab(title: "b", workingDirectory: "/b")
        b.customTitle = "renamed"
        w.select(id: b.id)

        let snap = ws.snapshot()
        XCTAssertEqual(snap.version, SessionSnapshot.currentVersion)
        XCTAssertEqual(snap.tabLayout, .strip)
        XCTAssertEqual(snap.windows.count, 1)
        XCTAssertEqual(snap.windows[0].frame, WindowFrame(x: 10, y: 20, width: 800, height: 600))
        XCTAssertEqual(snap.windows[0].tabs.map(\.title), ["a", "b"])
        XCTAssertEqual(snap.windows[0].tabs[1].customTitle, "renamed")
        XCTAssertEqual(snap.windows[0].selectedIndex, 1)
    }

    func testRoundTripThroughJSON() throws {
        let ws = Workspace()
        let w = ws.addWindow()
        _ = w.addTab(title: "a", workingDirectory: "/a")
        let snap = ws.snapshot()
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
    }

    func testRestoreRebuildsWorkspace() {
        let snap = SessionSnapshot(
            version: SessionSnapshot.currentVersion,
            tabLayout: .strip,
            windows: [
                WindowSnapshot(
                    frame: nil,
                    tabs: [TabSnapshot(title: "a", customTitle: nil, workingDirectory: "/a"),
                           TabSnapshot(title: "b", customTitle: "B", workingDirectory: "/b")],
                    selectedIndex: 0
                ),
            ]
        )
        let ws = Workspace.restore(from: snap, directoryExists: { _ in true })
        XCTAssertEqual(ws.tabLayout, .strip)
        XCTAssertEqual(ws.windows.count, 1)
        XCTAssertEqual(ws.windows[0].tabs.map(\.displayTitle), ["a", "B"])
        XCTAssertEqual(ws.windows[0].selectedTab?.title, "a")
    }

    func testRestoreFallsBackToHomeForMissingDirectories() {
        let snap = SessionSnapshot(
            version: 1, tabLayout: .sidebar,
            windows: [WindowSnapshot(frame: nil,
                                     tabs: [TabSnapshot(title: "x", customTitle: nil, workingDirectory: "/gone")],
                                     selectedIndex: 0)]
        )
        let ws = Workspace.restore(from: snap, directoryExists: { $0 != "/gone" }, fallbackDirectory: "/Users/me")
        XCTAssertEqual(ws.windows[0].tabs[0].workingDirectory, "/Users/me")
    }

    func testRestoreWithNoWindowsYieldsOneWindowWithOneTab() {
        let snap = SessionSnapshot(version: 1, tabLayout: .sidebar, windows: [])
        let ws = Workspace.restore(from: snap, directoryExists: { _ in true }, fallbackDirectory: "/Users/me")
        XCTAssertEqual(ws.windows.count, 1)
        XCTAssertEqual(ws.windows[0].tabs.count, 1)
        XCTAssertEqual(ws.windows[0].tabs[0].workingDirectory, "/Users/me")
    }

    func testRestoreClampsInvalidSelectedIndex() {
        let snap = SessionSnapshot(
            version: 1, tabLayout: .sidebar,
            windows: [WindowSnapshot(frame: nil,
                                     tabs: [TabSnapshot(title: "x", customTitle: nil, workingDirectory: "/")],
                                     selectedIndex: 7)]
        )
        let ws = Workspace.restore(from: snap, directoryExists: { _ in true })
        XCTAssertEqual(ws.windows[0].selectedTab?.title, "x")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SessionSnapshotTests`
Expected: compile error.

- [ ] **Step 3: Implement snapshot types and restore**

`Sources/WorkspaceModel/SessionSnapshot.swift`:

```swift
import Foundation

public struct TabSnapshot: Codable, Equatable, Sendable {
    public var title: String
    public var customTitle: String?
    public var workingDirectory: String
    public init(title: String, customTitle: String?, workingDirectory: String) {
        self.title = title; self.customTitle = customTitle; self.workingDirectory = workingDirectory
    }
}

public struct WindowSnapshot: Codable, Equatable, Sendable {
    public var frame: WindowFrame?
    public var tabs: [TabSnapshot]
    public var selectedIndex: Int?
    public init(frame: WindowFrame?, tabs: [TabSnapshot], selectedIndex: Int?) {
        self.frame = frame; self.tabs = tabs; self.selectedIndex = selectedIndex
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var tabLayout: TabLayout
    public var windows: [WindowSnapshot]
    public init(version: Int, tabLayout: TabLayout, windows: [WindowSnapshot]) {
        self.version = version; self.tabLayout = tabLayout; self.windows = windows
    }
}

extension Workspace {
    public func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            version: SessionSnapshot.currentVersion,
            tabLayout: tabLayout,
            windows: windows.map { w in
                WindowSnapshot(
                    frame: w.frame,
                    tabs: w.tabs.map { TabSnapshot(title: $0.title, customTitle: $0.customTitle, workingDirectory: $0.workingDirectory) },
                    selectedIndex: w.selectedTabID.flatMap(w.index(of:))
                )
            }
        )
    }

    /// Rebuilds a workspace. Directories that no longer exist fall back to `fallbackDirectory`.
    /// An empty snapshot yields one window with one tab so the app never launches with no terminal.
    public static func restore(
        from snapshot: SessionSnapshot,
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        fallbackDirectory: String = NSHomeDirectory()
    ) -> Workspace {
        let ws = Workspace(tabLayout: snapshot.tabLayout)
        for windowSnap in snapshot.windows {
            let w = ws.addWindow(frame: windowSnap.frame)
            for t in windowSnap.tabs {
                let dir = directoryExists(t.workingDirectory) ? t.workingDirectory : fallbackDirectory
                w.addTab(title: t.title, workingDirectory: dir, customTitle: t.customTitle)
            }
            if let i = windowSnap.selectedIndex, i >= 0, i < w.tabs.count {
                w.select(id: w.tabs[i].id)
            } else if let first = w.tabs.first {
                w.select(id: first.id)
            }
        }
        if ws.windows.isEmpty || ws.windows.allSatisfy(\.isEmpty) {
            let w = ws.windows.first ?? ws.addWindow()
            w.addTab(title: "", workingDirectory: fallbackDirectory)
        }
        return ws
    }
}
```

- [ ] **Step 4: Run snapshot tests**

Run: `swift test --filter SessionSnapshotTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Write failing SessionStore tests**

`Tests/WorkspaceModelTests/SessionStoreTests.swift`:

```swift
import XCTest
@testable import WorkspaceModel

final class SessionStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testLoadReturnsNilWhenFileMissing() {
        let store = SessionStore(url: dir.appendingPathComponent("session.json"))
        XCTAssertNil(store.load())
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = dir.appendingPathComponent("nested/session.json")
        let store = SessionStore(url: url)
        let snap = SessionSnapshot(version: 1, tabLayout: .strip, windows: [])
        try store.save(snap)
        XCTAssertEqual(store.load(), snap)
    }

    func testCorruptFileIsRenamedToBakAndLoadReturnsNil() throws {
        let url = dir.appendingPathComponent("session.json")
        try Data("{ not json".utf8).write(to: url)
        let store = SessionStore(url: url)
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".bak"))
    }

    func testNewerVersionIsTreatedAsCorrupt() throws {
        let url = dir.appendingPathComponent("session.json")
        let future = SessionSnapshot(version: SessionSnapshot.currentVersion + 1, tabLayout: .sidebar, windows: [])
        try JSONEncoder().encode(future).write(to: url)
        let store = SessionStore(url: url)
        XCTAssertNil(store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".bak"))
    }
}
```

- [ ] **Step 6: Implement SessionStore**

`Sources/WorkspaceModel/SessionStore.swift`:

```swift
import Foundation

public struct SessionStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PrompTTY", isDirectory: true).appendingPathComponent("session.json")
    }

    /// Returns nil when there is no session or it cannot be used. An unusable file is moved aside
    /// to `<name>.bak` so a bad file can never block launch twice.
    public func load() -> SessionSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let snap = try JSONDecoder().decode(SessionSnapshot.self, from: data)
            guard snap.version <= SessionSnapshot.currentVersion else { throw CocoaError(.coderInvalidValue) }
            return snap
        } catch {
            moveAside()
            return nil
        }
    }

    public func save(_ snapshot: SessionSnapshot) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    private func moveAside() {
        let bak = URL(fileURLWithPath: url.path + ".bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.moveItem(at: url, to: bak)
    }
}
```

- [ ] **Step 7: Run store tests**

Run: `swift test --filter SessionStoreTests`
Expected: PASS (4 tests).

- [ ] **Step 8: Write failing DebouncedSaver test**

`Tests/WorkspaceModelTests/DebouncedSaverTests.swift`:

```swift
import XCTest
@testable import WorkspaceModel

@MainActor
final class DebouncedSaverTests: XCTestCase {
    func testManySchedulesCoalesceIntoOneAction() async throws {
        var count = 0
        let saver = DebouncedSaver(delay: .milliseconds(50)) { count += 1 }
        for _ in 0..<10 { saver.schedule() }
        XCTAssertEqual(count, 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(count, 1)
    }

    func testFlushRunsPendingActionImmediatelyAndCancelsTimer() async throws {
        var count = 0
        let saver = DebouncedSaver(delay: .seconds(10)) { count += 1 }
        saver.schedule()
        saver.flush()
        XCTAssertEqual(count, 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(count, 1)
    }

    func testFlushWithoutPendingDoesNothing() {
        var count = 0
        let saver = DebouncedSaver(delay: .seconds(10)) { count += 1 }
        saver.flush()
        XCTAssertEqual(count, 0)
    }
}
```

- [ ] **Step 9: Implement DebouncedSaver**

`Sources/WorkspaceModel/DebouncedSaver.swift`:

```swift
import Foundation

/// Coalesces bursts of `schedule()` into one `action` after `delay` of quiet.
@MainActor
public final class DebouncedSaver {
    private let delay: Duration
    private let action: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    public init(delay: Duration, action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
    }

    public func schedule() {
        pending?.cancel()
        pending = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.pending = nil
            self.action()
        }
    }

    /// Runs the action now if one is pending.
    public func flush() {
        guard pending != nil else { return }
        pending?.cancel()
        pending = nil
        action()
    }
}
```

- [ ] **Step 10: Run all model tests**

Run: `swift test --filter WorkspaceModelTests`
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add Sources/WorkspaceModel Tests/WorkspaceModelTests
git commit -m "feat(model): session snapshot, JSON store with .bak recovery, debounced saver"
```

---

### Task 4: GhosttyAction decoding and the action sink protocol

**Files:**
- Create: `Sources/GhosttyBridge/GhosttyAction.swift`
- Create: `Sources/GhosttyBridge/GhosttyActionSink.swift`
- Test: `Tests/GhosttyBridgeTests/GhosttyActionTests.swift`

**Interfaces:**
- Produces:
  - `public enum GhosttyAction: Equatable, Sendable` with cases listed in Step 3. `init(_ c: ghostty_action_s)` is **internal**.
  - `public enum CloseTabMode: Sendable { case this, others, right }`
  - `public enum GotoTab: Equatable, Sendable { case index(Int), previous, next, last }`
  - `public enum MouseShape: Sendable { case `default`, text, pointer, crosshair, verticalText, notAllowed, grab, grabbing, resizeEW, resizeNS, resizeNESW, resizeNWSE, progress, wait, contextMenu, help, other }`
  - `public enum ColorKind: Equatable, Sendable { case foreground, background, cursor, palette(Int) }`
  - `public enum GhosttyActionTarget { case app; case surface(TerminalSurfaceView) }` (declared in Task 5 once `TerminalSurfaceView` exists; this task declares the sink protocol with the target type forward-declared as described in Step 4)
  - `@MainActor public protocol GhosttyActionSink: AnyObject { func handle(_ action: GhosttyAction, target: GhosttyActionTarget) -> Bool }`

- [ ] **Step 1: Write failing decoding tests**

`Tests/GhosttyBridgeTests/GhosttyActionTests.swift`:

```swift
import XCTest
import GhosttyKit
@testable import GhosttyBridge

final class GhosttyActionTests: XCTestCase {
    private func action(_ tag: ghostty_action_tag_e) -> ghostty_action_s {
        var a = ghostty_action_s()
        a.tag = tag
        return a
    }

    func testSimpleTags() {
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_QUIT)), .quit)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_NEW_WINDOW)), .newWindow)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_NEW_TAB)), .newTab)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_CLOSE_WINDOW)), .closeWindow)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_RENDER)), .render)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_OPEN_CONFIG)), .openConfig)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_CONFIG_CHANGE)), .configChange)
        XCTAssertEqual(GhosttyAction(action(GHOSTTY_ACTION_RING_BELL)), .ringBell)
    }

    func testCloseTabMode() {
        var a = action(GHOSTTY_ACTION_CLOSE_TAB)
        a.action.close_tab_mode = GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER
        XCTAssertEqual(GhosttyAction(a), .closeTab(.others))
    }

    func testGotoTabVariants() {
        var a = action(GHOSTTY_ACTION_GOTO_TAB)
        a.action.goto_tab = GHOSTTY_GOTO_TAB_PREVIOUS
        XCTAssertEqual(GhosttyAction(a), .gotoTab(.previous))
        a.action.goto_tab = GHOSTTY_GOTO_TAB_NEXT
        XCTAssertEqual(GhosttyAction(a), .gotoTab(.next))
        a.action.goto_tab = GHOSTTY_GOTO_TAB_LAST
        XCTAssertEqual(GhosttyAction(a), .gotoTab(.last))
        a.action.goto_tab = ghostty_action_goto_tab_e(rawValue: 3)
        XCTAssertEqual(GhosttyAction(a), .gotoTab(.index(3)))
    }

    func testMoveTab() {
        var a = action(GHOSTTY_ACTION_MOVE_TAB)
        a.action.move_tab.amount = -2
        XCTAssertEqual(GhosttyAction(a), .moveTab(-2))
    }

    func testStringPayloadsAreCopied() {
        var a = action(GHOSTTY_ACTION_SET_TITLE)
        let decoded: GhosttyAction = "hello".withCString { ptr in
            a.action.set_title.title = ptr
            return GhosttyAction(a)
        }
        XCTAssertEqual(decoded, .setTitle("hello"))

        var p = action(GHOSTTY_ACTION_PWD)
        let pwd: GhosttyAction = "/tmp/x".withCString { ptr in
            p.action.pwd.pwd = ptr
            return GhosttyAction(p)
        }
        XCTAssertEqual(pwd, .pwd("/tmp/x"))
    }

    func testNullStringBecomesEmpty() {
        let a = action(GHOSTTY_ACTION_SET_TITLE)
        XCTAssertEqual(GhosttyAction(a), .setTitle(""))
    }

    func testSizes() {
        var a = action(GHOSTTY_ACTION_INITIAL_SIZE)
        a.action.initial_size = ghostty_action_initial_size_s(width: 1200, height: 800)
        XCTAssertEqual(GhosttyAction(a), .initialSize(width: 1200, height: 800))

        var c = action(GHOSTTY_ACTION_CELL_SIZE)
        c.action.cell_size = ghostty_action_cell_size_s(width: 9, height: 20)
        XCTAssertEqual(GhosttyAction(c), .cellSize(width: 9, height: 20))
    }

    func testMouseShapeAndVisibility() {
        var a = action(GHOSTTY_ACTION_MOUSE_SHAPE)
        a.action.mouse_shape = GHOSTTY_MOUSE_SHAPE_TEXT
        XCTAssertEqual(GhosttyAction(a), .mouseShape(.text))
        a.action.mouse_shape = GHOSTTY_MOUSE_SHAPE_ZOOM_IN
        XCTAssertEqual(GhosttyAction(a), .mouseShape(.other))

        var v = action(GHOSTTY_ACTION_MOUSE_VISIBILITY)
        v.action.mouse_visibility = GHOSTTY_MOUSE_HIDDEN
        XCTAssertEqual(GhosttyAction(v), .mouseVisibility(visible: false))
    }

    func testColorChangeKinds() {
        var a = action(GHOSTTY_ACTION_COLOR_CHANGE)
        a.action.color_change = ghostty_action_color_change_s(kind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, r: 1, g: 2, b: 3)
        XCTAssertEqual(GhosttyAction(a), .colorChange(kind: .background, red: 1, green: 2, blue: 3))
        a.action.color_change.kind = ghostty_action_color_kind_e(rawValue: 7)
        XCTAssertEqual(GhosttyAction(a), .colorChange(kind: .palette(7), red: 1, green: 2, blue: 3))
    }

    func testReloadConfigSoftFlag() {
        var a = action(GHOSTTY_ACTION_RELOAD_CONFIG)
        a.action.reload_config.soft = true
        XCTAssertEqual(GhosttyAction(a), .reloadConfig(soft: true))
    }

    func testChildExitedAndNotification() {
        var a = action(GHOSTTY_ACTION_SHOW_CHILD_EXITED)
        a.action.child_exited = ghostty_surface_message_childexited_s(exit_code: 3, timetime_ms: 1500)
        XCTAssertEqual(GhosttyAction(a), .showChildExited(exitCode: 3, runtimeMs: 1500))

        var n = action(GHOSTTY_ACTION_DESKTOP_NOTIFICATION)
        let decoded: GhosttyAction = "T".withCString { t in
            "B".withCString { b in
                n.action.desktop_notification = ghostty_action_desktop_notification_s(title: t, body: b)
                return GhosttyAction(n)
            }
        }
        XCTAssertEqual(decoded, .desktopNotification(title: "T", body: "B"))
    }

    func testUnknownTagIsUnhandled() {
        let a = action(GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL)
        XCTAssertEqual(GhosttyAction(a), .unhandled(tag: GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL.rawValue))
        XCTAssertFalse(GhosttyAction(a).isImplemented)
        XCTAssertTrue(GhosttyAction.newTab.isImplemented)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter GhosttyActionTests`
Expected: compile error, `GhosttyAction` not found.

- [ ] **Step 3: Implement GhosttyAction**

`Sources/GhosttyBridge/GhosttyAction.swift`:

```swift
import GhosttyKit

public enum CloseTabMode: Equatable, Sendable { case this, others, right }

public enum GotoTab: Equatable, Sendable {
    /// 1-based, as in Ghostty's `goto_tab:N`.
    case index(Int)
    case previous, next, last
}

public enum MouseShape: Equatable, Sendable {
    case `default`, text, pointer, crosshair, verticalText, notAllowed, grab, grabbing
    case resizeEW, resizeNS, resizeNESW, resizeNWSE, progress, wait, contextMenu, help
    case other
}

public enum ColorKind: Equatable, Sendable {
    case foreground, background, cursor
    case palette(Int)
}

/// A libghostty runtime action, decoded into Swift. Anything the MVP does not implement
/// decodes to `.unhandled`, and the runtime returns `false` for it without consulting the sink.
public enum GhosttyAction: Equatable, Sendable {
    case quit
    case newWindow
    case newTab
    case closeTab(CloseTabMode)
    case closeWindow
    case gotoTab(GotoTab)
    case moveTab(Int)
    case setTitle(String)
    case setTabTitle(String)
    case pwd(String)
    case initialSize(width: UInt32, height: UInt32)
    case cellSize(width: UInt32, height: UInt32)
    case mouseShape(MouseShape)
    case mouseVisibility(visible: Bool)
    case render
    case colorChange(kind: ColorKind, red: UInt8, green: UInt8, blue: UInt8)
    case configChange
    case reloadConfig(soft: Bool)
    case openConfig
    case showChildExited(exitCode: UInt32, runtimeMs: UInt64)
    case desktopNotification(title: String, body: String)
    case ringBell
    /// Synthesized from `close_surface_cb`, not a `ghostty_action_tag_e`.
    case closeSurface(processAlive: Bool)
    case unhandled(tag: UInt32)

    public var isImplemented: Bool {
        if case .unhandled = self { return false }
        return true
    }

    init(_ c: ghostty_action_s) {
        switch c.tag {
        case GHOSTTY_ACTION_QUIT: self = .quit
        case GHOSTTY_ACTION_NEW_WINDOW: self = .newWindow
        case GHOSTTY_ACTION_NEW_TAB: self = .newTab
        case GHOSTTY_ACTION_CLOSE_WINDOW: self = .closeWindow
        case GHOSTTY_ACTION_RENDER: self = .render
        case GHOSTTY_ACTION_OPEN_CONFIG: self = .openConfig
        case GHOSTTY_ACTION_CONFIG_CHANGE: self = .configChange
        case GHOSTTY_ACTION_RING_BELL: self = .ringBell
        case GHOSTTY_ACTION_CLOSE_TAB:
            switch c.action.close_tab_mode {
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER: self = .closeTab(.others)
            case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT: self = .closeTab(.right)
            default: self = .closeTab(.this)
            }
        case GHOSTTY_ACTION_GOTO_TAB:
            switch c.action.goto_tab {
            case GHOSTTY_GOTO_TAB_PREVIOUS: self = .gotoTab(.previous)
            case GHOSTTY_GOTO_TAB_NEXT: self = .gotoTab(.next)
            case GHOSTTY_GOTO_TAB_LAST: self = .gotoTab(.last)
            default: self = .gotoTab(.index(Int(c.action.goto_tab.rawValue)))
            }
        case GHOSTTY_ACTION_MOVE_TAB:
            self = .moveTab(Int(c.action.move_tab.amount))
        case GHOSTTY_ACTION_SET_TITLE:
            self = .setTitle(Self.string(c.action.set_title.title))
        case GHOSTTY_ACTION_SET_TAB_TITLE:
            self = .setTabTitle(Self.string(c.action.set_tab_title.title))
        case GHOSTTY_ACTION_PWD:
            self = .pwd(Self.string(c.action.pwd.pwd))
        case GHOSTTY_ACTION_INITIAL_SIZE:
            self = .initialSize(width: c.action.initial_size.width, height: c.action.initial_size.height)
        case GHOSTTY_ACTION_CELL_SIZE:
            self = .cellSize(width: c.action.cell_size.width, height: c.action.cell_size.height)
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            self = .mouseShape(Self.mouseShape(c.action.mouse_shape))
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            self = .mouseVisibility(visible: c.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
        case GHOSTTY_ACTION_COLOR_CHANGE:
            let cc = c.action.color_change
            self = .colorChange(kind: Self.colorKind(cc.kind), red: cc.r, green: cc.g, blue: cc.b)
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            self = .reloadConfig(soft: c.action.reload_config.soft)
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            self = .showChildExited(exitCode: c.action.child_exited.exit_code, runtimeMs: c.action.child_exited.timetime_ms)
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = c.action.desktop_notification
            self = .desktopNotification(title: Self.string(n.title), body: Self.string(n.body))
        default:
            self = .unhandled(tag: c.tag.rawValue)
        }
    }

    /// Copies a C string before the callback returns; libghostty owns the memory only until then.
    private static func string(_ ptr: UnsafePointer<CChar>?) -> String {
        guard let ptr else { return "" }
        return String(cString: ptr)
    }

    private static func mouseShape(_ s: ghostty_action_mouse_shape_e) -> MouseShape {
        switch s {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: return .default
        case GHOSTTY_MOUSE_SHAPE_TEXT: return .text
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointer
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .verticalText
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: return .notAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .grab
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return .grabbing
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: return .resizeEW
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: return .resizeNS
        case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE: return .resizeNESW
        case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE: return .resizeNWSE
        case GHOSTTY_MOUSE_SHAPE_PROGRESS: return .progress
        case GHOSTTY_MOUSE_SHAPE_WAIT: return .wait
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return .contextMenu
        case GHOSTTY_MOUSE_SHAPE_HELP: return .help
        default: return .other
        }
    }

    private static func colorKind(_ k: ghostty_action_color_kind_e) -> ColorKind {
        switch k {
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND: return .foreground
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND: return .background
        case GHOSTTY_ACTION_COLOR_KIND_CURSOR: return .cursor
        default: return .palette(Int(k.rawValue))
        }
    }
}
```

If any `GHOSTTY_MOUSE_SHAPE_*` constant used above does not exist in the pinned header, delete that case; the header lists them at `ghostty_action_mouse_shape_e` (grep `GHOSTTY_MOUSE_SHAPE_` in `.build/checkouts/libghostty-spm/../GhosttyKit.xcframework/*/Headers/ghostty.h`).

- [ ] **Step 4: Sink protocol**

`Sources/GhosttyBridge/GhosttyActionSink.swift`:

```swift
/// Who an action is about. `TerminalSurfaceView` is defined in TerminalSurfaceView.swift (Task 5);
/// until that file exists, add a temporary `public final class TerminalSurfaceView {}` stub at the
/// bottom of this file and delete the stub in Task 5.
public enum GhosttyActionTarget {
    case app
    case surface(TerminalSurfaceView)
}

/// Implemented by the app. Return `true` only when the action was actually performed.
@MainActor
public protocol GhosttyActionSink: AnyObject {
    func handle(_ action: GhosttyAction, target: GhosttyActionTarget) -> Bool
}
```

Add at the bottom, to be removed in Task 5:

```swift
@MainActor public final class TerminalSurfaceView {}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter GhosttyActionTests`
Expected: PASS (12 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/GhosttyBridge Tests/GhosttyBridgeTests
git commit -m "feat(bridge): decode ghostty_action_s into a Swift GhosttyAction enum"
```

---

### Task 5: TerminalSurfaceView lifecycle and GhosttyRuntime

**Files:**
- Create: `Sources/GhosttyBridge/TerminalSurfaceView.swift`
- Create: `Sources/GhosttyBridge/GhosttyRuntime.swift`
- Modify: `Sources/GhosttyBridge/GhosttyActionSink.swift` (remove the stub)

**Interfaces:**
- Consumes: `GhosttyAction`, `GhosttyActionTarget`, `GhosttyActionSink` (Task 4).
- Produces:
  - `public struct GhosttyRuntimeError: Error { public let message: String }`
  - `@MainActor public final class GhosttyRuntime { init() throws; weak var sink: GhosttyActionSink?; private(set) var configDiagnostics: [String]; var onConfigDiagnostics: (([String]) -> Void)?; func tick(); func reloadConfig(); func openConfig(); func setFocus(_ focused: Bool); var needsConfirmQuit: Bool; func setColorScheme(dark: Bool) }`
  - `public struct TerminalSurfaceConfiguration { var workingDirectory: String?; init(workingDirectory:) }`
  - `@MainActor public final class TerminalSurfaceView: NSView { init(runtime:configuration:); var token: AnyHashable?; private(set) var pendingInitialSize: CGSize?; private(set) var cellSize: CGSize; private(set) var hasExited: Bool; var needsConfirmQuit: Bool; func teardown(); func requestClose(); func setOccluded(_:); func apply(mouseShape:); func markExited() }`
  - Internal: `var surface: UnsafeMutableRawPointer?`, `func completeClipboardRequest(_ string: String, state: UnsafeMutableRawPointer?, confirmed: Bool)`, `func noteInitialSize(_:)`, `func noteCellSize(_:)`.

- [ ] **Step 1: Remove the stub**

Delete the `@MainActor public final class TerminalSurfaceView {}` line from `GhosttyActionSink.swift`.

- [ ] **Step 2: Write TerminalSurfaceView (lifecycle half)**

`Sources/GhosttyBridge/TerminalSurfaceView.swift`:

```swift
import AppKit
import GhosttyKit
import QuartzCore

public struct TerminalSurfaceConfiguration: Sendable {
    public var workingDirectory: String?
    public init(workingDirectory: String? = nil) {
        self.workingDirectory = workingDirectory
    }
}

/// Hosts one libghostty surface in a Metal layer. Input handling lives in TerminalSurfaceView+Input.swift.
@MainActor
public final class TerminalSurfaceView: NSView {
    /// Opaque handle the app uses to find the owning tab. The bridge never reads it.
    public var token: AnyHashable?

    /// Size libghostty asked for during `ghostty_surface_new`, before this view had a window.
    public private(set) var pendingInitialSize: CGSize?
    public private(set) var cellSize: CGSize = .zero
    public private(set) var hasExited = false

    let runtime: GhosttyRuntime
    private let configuration: TerminalSurfaceConfiguration

    // Plain raw pointer: `ghostty_surface_t` is already an optional typealias (see Task 5 Step 3 note).
    nonisolated(unsafe) private(set) var surface: UnsafeMutableRawPointer?
    nonisolated(unsafe) private var isFreed = false

    // Input state shared with the +Input extension.
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    var currentMouseShape: MouseShape = .default
    var trackingArea: NSTrackingArea?

    // Read from `deinit`, which is nonisolated, hence `nonisolated(unsafe)`.
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

    public init(runtime: GhosttyRuntime, configuration: TerminalSurfaceConfiguration) {
        self.runtime = runtime
        self.configuration = configuration
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let surface, !isFreed {
            ghostty_surface_free(surface)
        }
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.displaySyncEnabled = true
        layer.framebufferOnly = true
        return layer
    }

    // MARK: Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
        windowObservers.removeAll()
        guard let window else { return }
        createSurfaceIfNeeded()
        let nc = NotificationCenter.default
        windowObservers = [
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusDidChange() }
            },
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusDidChange() }
            },
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateOcclusion() }
            },
        ]
        sizeDidChange()
        updateOcclusion()
        focusDidChange()
    }

    private func createSurfaceIfNeeded() {
        guard surface == nil, !isFreed else { return }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB
        let created: UnsafeMutableRawPointer? = withOptionalCString(configuration.workingDirectory) { dir in
            cfg.working_directory = dir
            return ghostty_surface_new(runtime.app, &cfg)
        }
        surface = created
        if created == nil {
            runtime.surfaceCreationFailed(self)
        }
    }

    /// Frees the surface exactly once. Safe to call from both the tab-close path and `close_surface_cb`.
    public func teardown() {
        guard let surface, !isFreed else { return }
        isFreed = true
        ghostty_surface_free(surface)
        self.surface = nil
    }

    public func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    public var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    public func markExited() { hasExited = true }

    // MARK: Geometry

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let window else { return }
        let scale = Double(window.backingScaleFactor)
        ghostty_surface_set_content_scale(surface, scale, scale)
        sizeDidChange()
    }

    private func sizeDidChange() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let w = UInt32(max(1, bounds.width * scale))
        let h = UInt32(max(1, bounds.height * scale))
        ghostty_surface_set_size(surface, w, h)
    }

    // MARK: Focus and visibility

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        focusDidChange()
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        focusDidChange()
        return ok
    }

    private func focusDidChange() {
        guard let surface else { return }
        let focused = (window?.isKeyWindow ?? false) && window?.firstResponder === self
        ghostty_surface_set_focus(surface, focused)
    }

    public override func viewDidHide() { super.viewDidHide(); updateOcclusion() }
    public override func viewDidUnhide() { super.viewDidUnhide(); updateOcclusion() }

    private var explicitlyOccluded = false

    /// Containers call this for tabs that are not selected so hidden surfaces stop rendering.
    public func setOccluded(_ occluded: Bool) {
        explicitlyOccluded = occluded
        updateOcclusion()
    }

    private func updateOcclusion() {
        guard let surface else { return }
        let windowVisible = window?.occlusionState.contains(.visible) ?? false
        let visible = windowVisible && !isHiddenOrHasHiddenAncestor && !explicitlyOccluded
        ghostty_surface_set_occlusion(surface, visible)
    }

    // MARK: Runtime hooks (internal)

    func noteInitialSize(_ size: CGSize) { pendingInitialSize = size }
    func noteCellSize(_ size: CGSize) { cellSize = size }

    func completeClipboardRequest(_ string: String, state: UnsafeMutableRawPointer?, confirmed: Bool) {
        guard let surface else { return }
        string.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
        }
    }
}

func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString { body($0) }
}
```

- [ ] **Step 3: Write GhosttyRuntime**

Note on types: libghostty's opaque handles are `typedef void*`, which Swift imports as
`typealias ghostty_app_t = UnsafeMutableRawPointer?` (already optional). Writing `ghostty_app_t?`
or `ghostty_app_t!` therefore creates a double optional. Store handles as plain
`UnsafeMutableRawPointer` and pass them to the C functions directly; Swift promotes to the optional
typealias at the call site.

`Sources/GhosttyBridge/GhosttyRuntime.swift`:

```swift
import AppKit
import GhosttyKit
import GhosttyKitResources

public struct GhosttyRuntimeError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Owns the single `ghostty_app_t` for the process and the six runtime callbacks.
/// Everything is main-actor; `wakeup_cb` is the only callback libghostty invokes off-main and it
/// only schedules `tick()`.
@MainActor
public final class GhosttyRuntime {
    /// IUO because `ghostty_app_new` needs a pointer to `self` as userdata, so it runs after all
    /// other stored properties are initialized.
    nonisolated(unsafe) private var appHandle: UnsafeMutableRawPointer!
    nonisolated(unsafe) private var config: UnsafeMutableRawPointer

    var app: UnsafeMutableRawPointer { appHandle }

    public weak var sink: GhosttyActionSink?
    public private(set) var configDiagnostics: [String] = []
    /// Called after every reload with the current diagnostics (possibly empty).
    public var onConfigDiagnostics: (([String]) -> Void)?
    /// Called when `ghostty_surface_new` fails for a view.
    public var onSurfaceCreationFailed: ((TerminalSurfaceView) -> Void)?

    public init() throws {
        let resources = GhosttyKitResources.directoryURL
        guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("terminfo").path) else {
            throw GhosttyRuntimeError(message: "libghostty resources missing at \(resources.path); this is a packaging bug")
        }
        setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
            throw GhosttyRuntimeError(message: "ghostty_init failed")
        }
        let (cfg, diags) = Self.loadConfig()
        config = cfg
        configDiagnostics = diags

        var rc = ghostty_runtime_config_s()
        rc.userdata = Unmanaged.passUnretained(self).toOpaque()
        rc.supports_selection_clipboard = false
        rc.wakeup_cb = ghosttyWakeup
        rc.action_cb = ghosttyAction
        rc.read_clipboard_cb = ghosttyReadClipboard
        rc.confirm_read_clipboard_cb = ghosttyConfirmReadClipboard
        rc.write_clipboard_cb = ghosttyWriteClipboard
        rc.close_surface_cb = ghosttyCloseSurface

        guard let created = ghostty_app_new(&rc, cfg) else {
            ghostty_config_free(cfg)
            throw GhosttyRuntimeError(message: "ghostty_app_new failed")
        }
        appHandle = created
    }

    deinit {
        if let appHandle { ghostty_app_free(appHandle) }
        ghostty_config_free(config)
    }

    // MARK: Public API

    public func tick() { ghostty_app_tick(app) }

    public func reloadConfig() {
        let (cfg, diags) = Self.loadConfig()
        ghostty_app_update_config(app, cfg)
        ghostty_config_free(config)
        config = cfg
        configDiagnostics = diags
        onConfigDiagnostics?(diags)
    }

    public func openConfig() { ghostty_app_open_config(app) }

    public func setFocus(_ focused: Bool) { ghostty_app_set_focus(app, focused) }

    public var needsConfirmQuit: Bool { ghostty_app_needs_confirm_quit(app) }

    public func setColorScheme(dark: Bool) {
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    // MARK: Internal

    func surfaceCreationFailed(_ view: TerminalSurfaceView) {
        onSurfaceCreationFailed?(view)
    }

    /// Entry point from `action_cb`. Returns whether the action was performed.
    func dispatch(target cTarget: ghostty_target_s, action cAction: ghostty_action_s) -> Bool {
        if cAction.tag == GHOSTTY_ACTION_CONFIG_CHANGE, let newConfig = cAction.action.config_change.config {
            // libghostty keeps ownership of the passed config; clone to keep our own copy current.
            if let clone = ghostty_config_clone(newConfig) {
                ghostty_config_free(config)
                config = clone
            }
        }

        let action = GhosttyAction(cAction)
        guard action.isImplemented else { return false }

        let target: GhosttyActionTarget
        switch cTarget.tag {
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = cTarget.target.surface, let ud = ghostty_surface_userdata(surface) else { return false }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
            switch action {
            case .initialSize(let w, let h): view.noteInitialSize(CGSize(width: Double(w), height: Double(h)))
            case .cellSize(let w, let h): view.noteCellSize(CGSize(width: Double(w), height: Double(h)))
            case .showChildExited: view.markExited()
            case .mouseShape(let shape): view.apply(mouseShape: shape)
            case .mouseVisibility(let visible): if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
            default: break
            }
            target = .surface(view)
        default:
            target = .app
        }

        switch action {
        case .reloadConfig:
            reloadConfig()
            return true
        case .openConfig:
            openConfig()
            return true
        case .mouseShape, .mouseVisibility:
            return true
        default:
            return sink?.handle(action, target: target) ?? false
        }
    }

    private static func loadConfig() -> (UnsafeMutableRawPointer, [String]) {
        let cfg = ghostty_config_new()!
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        var diags: [String] = []
        let count = ghostty_config_diagnostics_count(cfg)
        for i in 0..<count {
            let d = ghostty_config_get_diagnostic(cfg, i)
            if let m = d.message { diags.append(String(cString: m)) }
        }
        return (cfg, diags)
    }
}
```

- [ ] **Step 4: Add the C callbacks at file scope (bottom of GhosttyRuntime.swift)**

```swift
// MARK: - C callbacks
// These must be plain functions (no captures) so they convert to @convention(c) pointers.

private struct SendablePointer: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer
}

/// Called from any thread. Only schedules a tick.
private func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let box = SendablePointer(raw: userdata)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            Unmanaged<GhosttyRuntime>.fromOpaque(box.raw).takeUnretainedValue().tick()
        }
    }
}

/// Called on the main thread during `ghostty_app_tick` or synchronously inside `ghostty_surface_new`.
private func ghosttyAction(_ app: UnsafeMutableRawPointer?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    MainActor.assumeIsolated {
        guard let app, let ud = ghostty_app_userdata(app) else { return false }
        return Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue().dispatch(target: target, action: action)
    }
}

/// `userdata` here is the *surface's* userdata (our view), not the app's.
private func ghosttyReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool {
    MainActor.assumeIsolated {
        guard let userdata, location == GHOSTTY_CLIPBOARD_STANDARD else { return false }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        view.completeClipboardRequest(text, state: state, confirmed: false)
        return true
    }
}

/// MVP policy: approve every paste/OSC 52 request without prompting.
private func ghosttyConfirmReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ string: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e) {
    MainActor.assumeIsolated {
        guard let userdata else { return }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        let text = string.map { String(cString: $0) } ?? ""
        view.completeClipboardRequest(text, state: state, confirmed: true)
    }
}

private func ghosttyWriteClipboard(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ contents: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int, _ confirm: Bool) {
    MainActor.assumeIsolated {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let contents, count > 0 else { return }
        for i in 0..<count {
            let item = contents[i]
            guard let mime = item.mime, let data = item.data else { continue }
            if String(cString: mime) == "text/plain" {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(String(cString: data), forType: .string)
                return
            }
        }
    }
}

/// May be invoked synchronously from inside our own teardown, so hop to the next run-loop turn
/// before touching the model.
private func ghosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    guard let userdata else { return }
    let box = SendablePointer(raw: userdata)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(box.raw).takeUnretainedValue()
            _ = view.runtime.sink?.handle(.closeSurface(processAlive: processAlive), target: .surface(view))
        }
    }
}
```

- [ ] **Step 5: Add a temporary `apply(mouseShape:)` so the module compiles**

Append to `TerminalSurfaceView.swift` (Task 6 moves the body into the input extension with real cursor mapping; keep this exact signature):

```swift
extension TerminalSurfaceView {
    public func apply(mouseShape: MouseShape) {
        currentMouseShape = mouseShape
        window?.invalidateCursorRects(for: self)
    }
}
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: succeeds with no errors. Warnings about `nonisolated(unsafe)` are acceptable; errors about sendability are not.

If `GhosttyKitResources.directoryURL` does not compile, open `.build/checkouts/libghostty-spm/Sources/GhosttyKitResources/` and use the public symbol it actually exports for the resources directory (the package README documents `GhosttyKitResources.directoryURL`). Do not compute the path by hand from `Bundle.main`.

- [ ] **Step 7: Run existing tests to make sure nothing regressed**

Run: `swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/GhosttyBridge
git commit -m "feat(bridge): GhosttyRuntime with C callbacks and TerminalSurfaceView lifecycle"
```

---

### Task 6: Keyboard, IME, and mouse input

**Files:**
- Create: `Sources/GhosttyBridge/InputTranslation.swift`
- Create: `Sources/GhosttyBridge/TerminalSurfaceView+Input.swift`
- Modify: `Sources/GhosttyBridge/TerminalSurfaceView.swift` (remove the temporary `apply(mouseShape:)` extension from Task 5 Step 5)
- Test: `Tests/GhosttyBridgeTests/InputTranslationTests.swift`

**Interfaces:**
- Consumes: `TerminalSurfaceView` internals `surface`, `markedText`, `keyTextAccumulator`, `currentMouseShape`, `trackingArea` (Task 5).
- Produces (internal): `enum InputTranslation { static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e; static func mouseButton(_ buttonNumber: Int) -> ghostty_input_mouse_button_e; static func scrollMods(precision: Bool, momentumPhase: NSEvent.Phase) -> ghostty_input_scroll_mods_t; static func modifierKey(forKeyCode: UInt16) -> NSEvent.ModifierFlags? }`
- Produces (public): `TerminalSurfaceView.apply(mouseShape:)`, full `NSTextInputClient` conformance.

- [ ] **Step 1: Write failing translation tests**

`Tests/GhosttyBridgeTests/InputTranslationTests.swift`:

```swift
import XCTest
import AppKit
import GhosttyKit
@testable import GhosttyBridge

final class InputTranslationTests: XCTestCase {
    func testBasicModifiers() {
        XCTAssertEqual(InputTranslation.mods([]).rawValue, GHOSTTY_MODS_NONE.rawValue)
        XCTAssertEqual(InputTranslation.mods([.shift]).rawValue, GHOSTTY_MODS_SHIFT.rawValue)
        XCTAssertEqual(InputTranslation.mods([.command, .option]).rawValue,
                       GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_ALT.rawValue)
        XCTAssertEqual(InputTranslation.mods([.control, .capsLock]).rawValue,
                       GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_CAPS.rawValue)
    }

    func testRightSideModifiersUseDeviceBits() {
        let rightShift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | InputTranslation.deviceRightShift)
        XCTAssertEqual(InputTranslation.mods(rightShift).rawValue,
                       GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_SHIFT_RIGHT.rawValue)
        let rightCmd = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | InputTranslation.deviceRightCommand)
        XCTAssertEqual(InputTranslation.mods(rightCmd).rawValue,
                       GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SUPER_RIGHT.rawValue)
    }

    func testMouseButtons() {
        XCTAssertEqual(InputTranslation.mouseButton(0), GHOSTTY_MOUSE_LEFT)
        XCTAssertEqual(InputTranslation.mouseButton(1), GHOSTTY_MOUSE_RIGHT)
        XCTAssertEqual(InputTranslation.mouseButton(2), GHOSTTY_MOUSE_MIDDLE)
        XCTAssertEqual(InputTranslation.mouseButton(3), GHOSTTY_MOUSE_FOUR)
        XCTAssertEqual(InputTranslation.mouseButton(4), GHOSTTY_MOUSE_FIVE)
        XCTAssertEqual(InputTranslation.mouseButton(9), GHOSTTY_MOUSE_UNKNOWN)
    }

    func testScrollModsPackPrecisionInBitZeroAndMomentumAbove() {
        XCTAssertEqual(InputTranslation.scrollMods(precision: false, momentumPhase: []), 0)
        XCTAssertEqual(InputTranslation.scrollMods(precision: true, momentumPhase: []), 1)
        XCTAssertEqual(InputTranslation.scrollMods(precision: true, momentumPhase: .changed),
                       1 | (Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue) << 1))
        XCTAssertEqual(InputTranslation.scrollMods(precision: false, momentumPhase: .ended),
                       Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue) << 1)
    }

    func testModifierKeyCodes() {
        XCTAssertEqual(InputTranslation.modifierKey(forKeyCode: 56), .shift)
        XCTAssertEqual(InputTranslation.modifierKey(forKeyCode: 60), .shift)
        XCTAssertEqual(InputTranslation.modifierKey(forKeyCode: 55), .command)
        XCTAssertEqual(InputTranslation.modifierKey(forKeyCode: 58), .option)
        XCTAssertEqual(InputTranslation.modifierKey(forKeyCode: 59), .control)
        XCTAssertEqual(InputTranslation.modifierKey(forKeyCode: 57), .capsLock)
        XCTAssertNil(InputTranslation.modifierKey(forKeyCode: 0))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter InputTranslationTests`
Expected: compile error.

- [ ] **Step 3: Implement InputTranslation**

`Sources/GhosttyBridge/InputTranslation.swift`:

```swift
import AppKit
import GhosttyKit

/// Pure NSEvent → libghostty input conversions. No surface access, fully testable.
enum InputTranslation {
    // Device-dependent modifier bits from IOKit's IOLLEvent.h (NX_DEVICER*KEYMASK).
    // AppKit preserves them in ModifierFlags.rawValue; there is no named constant in AppKit.
    static let deviceRightShift: UInt = 0x0000_0004
    static let deviceRightControl: UInt = 0x0000_2000
    static let deviceRightOption: UInt = 0x0000_0040
    static let deviceRightCommand: UInt = 0x0000_0010

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        let device = flags.rawValue
        if device & deviceRightShift != 0 { raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if device & deviceRightControl != 0 { raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if device & deviceRightOption != 0 { raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if device & deviceRightCommand != 0 { raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    static func mouseButton(_ buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    /// Mirrors Ghostty's packed ScrollMods: bit 0 = precision, bits 1..3 = momentum.
    static func scrollMods(precision: Bool, momentumPhase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var packed: Int32 = precision ? 1 : 0
        let momentum: ghostty_input_mouse_momentum_e
        switch momentumPhase {
        case .began: momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        default: momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        packed |= Int32(momentum.rawValue) << 1
        return packed
    }

    /// Which modifier a `flagsChanged` event's keyCode refers to.
    static func modifierKey(forKeyCode code: UInt16) -> NSEvent.ModifierFlags? {
        switch code {
        case 56, 60: return .shift
        case 59, 62: return .control
        case 58, 61: return .option
        case 55, 54: return .command
        case 57: return .capsLock
        default: return nil
        }
    }
}
```

If `ghostty_input_mods_e.rawValue` is `Int32` rather than `UInt32` in the imported module, change the `raw` variable type to match; the compiler error will say which.

- [ ] **Step 4: Run translation tests**

Run: `swift test --filter InputTranslationTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Remove the temporary extension from Task 5 and write the input extension**

Delete the `extension TerminalSurfaceView { public func apply(mouseShape:) ... }` block at the bottom of `TerminalSurfaceView.swift`.

`Sources/GhosttyBridge/TerminalSurfaceView+Input.swift`:

```swift
import AppKit
import GhosttyKit

extension TerminalSurfaceView {
    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        // Let the text system run first so IME, dead keys, and `insertText` happen; we collect the
        // resulting text and send one key event with it attached.
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let collected = keyTextAccumulator ?? []
        keyTextAccumulator = nil

        var key = makeKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        key.composing = markedText.length > 0
        let text = collected.joined()
        if text.isEmpty {
            _ = ghostty_surface_key(surface, key)
        } else {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        }
    }

    public override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        let key = makeKey(event, action: GHOSTTY_ACTION_RELEASE)
        _ = ghostty_surface_key(surface, key)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard let surface, let flag = InputTranslation.modifierKey(forKeyCode: event.keyCode) else { return }
        let pressed = event.modifierFlags.contains(flag)
        var key = makeKey(event, action: pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        key.text = nil
        _ = ghostty_surface_key(surface, key)
    }

    /// Swallow text-system commands (moveLeft:, deleteBackward:, …) so AppKit does not beep;
    /// libghostty gets the raw key and encodes it itself.
    public override func doCommand(by selector: Selector) {}

    private func makeKey(_ event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        let mods = InputTranslation.mods(event.modifierFlags)
        key.mods = mods
        key.consumed_mods = surface.map { ghostty_surface_key_translation_mods($0, mods) } ?? GHOSTTY_MODS_NONE
        if event.type == .keyDown || event.type == .keyUp,
           let unshifted = event.characters(byApplyingModifiers: []),
           let scalar = unshifted.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        key.text = nil
        key.composing = false
        return key
    }

    // MARK: Mouse

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseDown(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event) }
    public override func mouseUp(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event) }
    public override func rightMouseDown(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) }
    public override func rightMouseUp(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) }
    public override func otherMouseDown(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_PRESS, InputTranslation.mouseButton(event.buttonNumber), event)
    }
    public override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, InputTranslation.mouseButton(event.buttonNumber), event)
    }

    public override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
    public override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
    public override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }
    public override func otherMouseDragged(with event: NSEvent) { sendMousePosition(event) }

    public override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, InputTranslation.mods(event.modifierFlags))
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if !precise {
            // Line-based deltas are tiny; Ghostty's own app scales them the same way.
            x *= 10
            y *= 10
        }
        let mods = InputTranslation.scrollMods(precision: precise, momentumPhase: event.momentumPhase)
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    public override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    private func sendMouseButton(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) {
        guard let surface else { return }
        if state == GHOSTTY_MOUSE_PRESS, window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, state, button, InputTranslation.mods(event.modifierFlags))
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        // libghostty wants a top-left origin; AppKit views are bottom-left unless flipped.
        ghostty_surface_mouse_pos(surface, p.x, bounds.height - p.y, InputTranslation.mods(event.modifierFlags))
    }

    // MARK: Cursor

    public func apply(mouseShape: MouseShape) {
        currentMouseShape = mouseShape
        window?.invalidateCursorRects(for: self)
        cursor(for: mouseShape).set()
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor(for: currentMouseShape))
    }

    private func cursor(for shape: MouseShape) -> NSCursor {
        switch shape {
        case .default, .other, .progress, .wait: return .arrow
        case .text: return .iBeam
        case .pointer: return .pointingHand
        case .crosshair: return .crosshair
        case .verticalText: return .iBeamCursorForVerticalLayout
        case .notAllowed: return .operationNotAllowed
        case .grab: return .openHand
        case .grabbing: return .closedHand
        case .resizeEW: return .resizeLeftRight
        case .resizeNS: return .resizeUpDown
        case .resizeNESW, .resizeNWSE: return .arrow
        case .contextMenu: return .contextualMenu
        case .help: return .arrow
        }
    }
}

// MARK: - NSTextInputClient

extension TerminalSurfaceView: NSTextInputClient {
    public func hasMarkedText() -> Bool { markedText.length > 0 }

    public func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString: markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String: markedText = NSMutableAttributedString(string: plain)
        default: return
        }
        guard let surface else { return }
        let s = markedText.string
        s.withCString { ptr in ghostty_surface_preedit(surface, ptr, UInt(strlen(ptr))) }
    }

    public func unmarkText() {
        markedText = NSMutableAttributedString()
        guard let surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        // libghostty reports top-left origin in points; convert to AppKit bottom-left, then to screen.
        let viewRect = NSRect(x: x, y: bounds.height - y - h, width: w, height: h)
        let windowRect = convert(viewRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let attributed as NSAttributedString: text = attributed.string
        case let plain as String: text = plain
        default: return
        }
        if markedText.length > 0 { unmarkText() }
        if keyTextAccumulator != nil {
            // Inside keyDown: attach to the key event instead of sending separately.
            keyTextAccumulator?.append(text)
            return
        }
        // Outside keyDown (e.g. IME candidate chosen with the mouse): send as plain text.
        guard let surface else { return }
        text.withCString { ptr in ghostty_surface_text(surface, ptr, UInt(strlen(ptr))) }
    }
}
```

- [ ] **Step 6: Build and run all bridge tests**

Run: `swift build && swift test --filter GhosttyBridgeTests`
Expected: build succeeds, all tests PASS. If `ghostty_surface_preedit` / `ghostty_surface_text` want `UInt` vs `Int` for length, follow the compiler.

- [ ] **Step 7: Commit**

```bash
git add Sources/GhosttyBridge Tests/GhosttyBridgeTests
git commit -m "feat(bridge): keyboard, IME, mouse, scroll and cursor handling for TerminalSurfaceView"
```

---

### Task 7: Window chrome with one working terminal

**Files:**
- Modify: `Sources/PrompTTYApp/AppDelegate.swift` (replace body)
- Create: `Sources/PrompTTYApp/WorkspaceCoordinator.swift`
- Create: `Sources/PrompTTYApp/Chrome/TerminalWindowController.swift`
- Create: `Sources/PrompTTYApp/Chrome/ChromeView.swift`
- Create: `Sources/PrompTTYApp/Chrome/ChromeTint.swift`
- Create: `Sources/PrompTTYApp/Chrome/TerminalContainerView.swift`

**Interfaces:**
- Consumes: `Workspace`, `WindowState`, `Tab`, `TabID`, `WindowID`, `WindowFrame`, `TabLayout` (Tasks 2–3); `GhosttyRuntime`, `TerminalSurfaceView`, `TerminalSurfaceConfiguration`, `GhosttyAction`, `GhosttyActionTarget`, `GhosttyActionSink` (Tasks 4–6).
- Produces:
  - `@MainActor final class WorkspaceCoordinator: GhosttyActionSink { init(runtime:workspace:); func start(); func newWindow(workingDirectory:); func newTab(in: WindowState, workingDirectory: String?); func closeTab(_ id: TabID); func select(_ id: TabID); func controller(for: WindowID) -> TerminalWindowController?; var onModelChanged: (() -> Void)? }`
  - `@MainActor final class TerminalWindowController: NSWindowController { init(state: WindowState, coordinator: WorkspaceCoordinator, runtime: GhosttyRuntime); let state: WindowState; func reload(); func surfaceView(for: Tab) -> TerminalSurfaceView; func removeSurface(for: TabID); func applyInitialTerminalSize(_: CGSize); func setTabLayout(_:hidden:) }`
  - `@MainActor final class ChromeView: NSView { init(); var tint: NSColor; let container: TerminalContainerView; func install(tabList: NSView?, layout: TabLayout); func setBanner(_: NSView?) }`
  - `enum ChromeTint { static func tint(forTerminalBackground: NSColor) -> NSColor; static let fallback: NSColor }`
  - `@MainActor final class TerminalContainerView: NSView { func show(_ view: TerminalSurfaceView); func remove(_ view: TerminalSurfaceView); func showExitedOverlay(for: TerminalSurfaceView, exitCode: UInt32, onClose: @escaping () -> Void); static let inset: CGFloat; static let cornerRadius: CGFloat }`

- [ ] **Step 1: ChromeTint**

`Sources/PrompTTYApp/Chrome/ChromeTint.swift`:

```swift
import AppKit

/// Arc-style chrome: a tinted frame derived from the terminal theme's background.
enum ChromeTint {
    static let fallback = NSColor(calibratedRed: 0.81, green: 0.80, blue: 0.96, alpha: 1)

    /// Dark themes get a slightly lighter frame; light themes a slightly darker one, so the
    /// terminal card always reads as inset.
    static func tint(forTerminalBackground bg: NSColor) -> NSColor {
        guard let rgb = bg.usingColorSpace(.sRGB) else { return fallback }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        let target: NSColor = luminance < 0.5 ? .white : .black
        let amount: CGFloat = luminance < 0.5 ? 0.12 : 0.07
        return rgb.blended(withFraction: amount, of: target) ?? fallback
    }
}
```

- [ ] **Step 2: TerminalContainerView**

`Sources/PrompTTYApp/Chrome/TerminalContainerView.swift`:

```swift
import AppKit
import GhosttyBridge

/// The rounded card that holds the selected tab's surface. Keeps every tab's surface alive
/// (hidden and occluded) so switching tabs is instant.
@MainActor
final class TerminalContainerView: NSView {
    static let inset: CGFloat = 8
    static let cornerRadius: CGFloat = 10

    private var overlays: [ObjectIdentifier: NSView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ view: TerminalSurfaceView) {
        if view.superview !== self {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        for sub in subviews {
            guard let surface = sub as? TerminalSurfaceView else { continue }
            let selected = surface === view
            surface.isHidden = !selected
            surface.setOccluded(!selected)
        }
        overlays.values.forEach { $0.isHidden = true }
        overlays[ObjectIdentifier(view)]?.isHidden = false
        window?.makeFirstResponder(view)
    }

    func remove(_ view: TerminalSurfaceView) {
        overlays.removeValue(forKey: ObjectIdentifier(view))?.removeFromSuperview()
        view.removeFromSuperview()
    }

    func showExitedOverlay(for view: TerminalSurfaceView, exitCode: UInt32, onClose: @escaping () -> Void) {
        let key = ObjectIdentifier(view)
        overlays[key]?.removeFromSuperview()
        let overlay = ExitedOverlayView(exitCode: exitCode, onClose: onClose)
        overlay.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 44)
        overlay.autoresizingMask = [.width, .maxYMargin]
        overlay.isHidden = view.isHidden
        addSubview(overlay)
        overlays[key] = overlay
    }
}

private final class ExitedOverlayView: NSView {
    init(exitCode: UInt32, onClose: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        let label = NSTextField(labelWithString: exitCode == 0 ? "Process exited" : "Process exited with code \(exitCode)")
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let button = NSButton(title: "Close tab", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        let handler = ClosureTarget(onClose)
        button.target = handler
        button.action = #selector(ClosureTarget.fire)
        self.handler = handler
        let stack = NSStackView(views: [label, NSView(), button])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    private var handler: ClosureTarget?
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// Lets a plain closure be an AppKit target/action.
final class ClosureTarget: NSObject {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire() { body() }
}
```

- [ ] **Step 3: ChromeView**

`Sources/PrompTTYApp/Chrome/ChromeView.swift`:

```swift
import AppKit
import WorkspaceModel

/// Tinted frame hosting the tab list (sidebar or strip), an optional banner, and the terminal card.
@MainActor
final class ChromeView: NSView {
    static let sidebarWidth: CGFloat = 220
    static let stripHeight: CGFloat = 36
    /// Space reserved for the system traffic lights, which sit over our content.
    static let trafficLightsHeight: CGFloat = 38
    static let trafficLightsWidth: CGFloat = 78

    let container = TerminalContainerView(frame: .zero)
    private var tabList: NSView?
    private var banner: NSView?
    private var layoutConstraints: [NSLayoutConstraint] = []
    private var layoutMode: TabLayout = .sidebar

    var tint: NSColor = ChromeTint.fallback {
        didSet { layer?.backgroundColor = tint.cgColor }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        wantsLayer = true
        layer?.backgroundColor = tint.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Pass `nil` to hide the tab list entirely (⌘B); the terminal card then fills the window.
    func install(tabList view: NSView?, layout: TabLayout) {
        tabList?.removeFromSuperview()
        tabList = view
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        layoutMode = layout
        relayout()
    }

    func setBanner(_ view: NSView?) {
        banner?.removeFromSuperview()
        banner = view
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        relayout()
    }

    private func relayout() {
        NSLayoutConstraint.deactivate(layoutConstraints)
        layoutConstraints.removeAll()
        let inset = TerminalContainerView.inset
        var c: [NSLayoutConstraint] = []

        // The vertical stack on the terminal side: [banner?] then container.
        let topAnchorForContent: NSLayoutYAxisAnchor
        if let banner {
            c += [
                banner.heightAnchor.constraint(equalToConstant: 32),
            ]
            topAnchorForContent = banner.bottomAnchor
        } else {
            topAnchorForContent = topAnchor
        }

        switch layoutMode {
        case .sidebar:
            if let tabList {
                c += [
                    tabList.leadingAnchor.constraint(equalTo: leadingAnchor),
                    tabList.topAnchor.constraint(equalTo: topAnchor, constant: Self.trafficLightsHeight),
                    tabList.bottomAnchor.constraint(equalTo: bottomAnchor),
                    tabList.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
                ]
            }
            let leading = tabList?.trailingAnchor ?? leadingAnchor
            if let banner {
                c += [
                    banner.leadingAnchor.constraint(equalTo: leading, constant: inset),
                    banner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                    banner.topAnchor.constraint(equalTo: topAnchor, constant: inset),
                ]
            }
            c += [
                container.leadingAnchor.constraint(equalTo: leading, constant: tabList == nil ? inset : 0),
                container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                container.topAnchor.constraint(equalTo: topAnchorForContent, constant: inset),
                container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            ]
        case .strip:
            if let tabList {
                c += [
                    tabList.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.trafficLightsWidth),
                    tabList.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                    tabList.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                    tabList.heightAnchor.constraint(equalToConstant: Self.stripHeight),
                ]
            }
            let top = tabList?.bottomAnchor ?? topAnchor
            if let banner {
                c += [
                    banner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                    banner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                    banner.topAnchor.constraint(equalTo: top, constant: inset),
                ]
            }
            c += [
                container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                container.topAnchor.constraint(equalTo: banner == nil ? top : topAnchorForContent, constant: inset),
                container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            ]
        }
        layoutConstraints = c
        NSLayoutConstraint.activate(c)
    }
}
```

- [ ] **Step 4: TerminalWindowController**

`Sources/PrompTTYApp/Chrome/TerminalWindowController.swift`:

```swift
import AppKit
import GhosttyBridge
import WorkspaceModel

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    let state: WindowState
    private unowned let coordinator: WorkspaceCoordinator
    private let runtime: GhosttyRuntime
    let chrome = ChromeView()
    private var surfaces: [TabID: TerminalSurfaceView] = [:]
    private var appliedInitialSize = false

    init(state: WindowState, coordinator: WorkspaceCoordinator, runtime: GhosttyRuntime) {
        self.state = state
        self.coordinator = coordinator
        self.runtime = runtime
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 300)
        super.init(window: window)
        window.delegate = self
        window.contentView = chrome
        if let frame = state.frame {
            window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
            appliedInitialSize = true
        } else {
            window.center()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Re-syncs the visible surface with the model. Called by the coordinator after every mutation.
    func reload() {
        guard let tab = state.selectedTab else { return }
        let view = surfaceView(for: tab)
        chrome.container.show(view)
        window?.title = tab.displayTitle
    }

    func surfaceView(for tab: Tab) -> TerminalSurfaceView {
        if let existing = surfaces[tab.id] { return existing }
        let view = TerminalSurfaceView(
            runtime: runtime,
            configuration: TerminalSurfaceConfiguration(workingDirectory: tab.workingDirectory)
        )
        view.token = tab.id
        surfaces[tab.id] = view
        return view
    }

    func removeSurface(for id: TabID) {
        guard let view = surfaces.removeValue(forKey: id) else { return }
        chrome.container.remove(view)
        view.teardown()
    }

    func allSurfaces() -> [TerminalSurfaceView] { Array(surfaces.values) }

    /// Sizes a fresh window so the terminal grid matches Ghostty's configured default size.
    func applyInitialTerminalSize(_ size: CGSize) {
        guard !appliedInitialSize, let window else { return }
        appliedInitialSize = true
        let inset = TerminalContainerView.inset
        let chromeW = coordinator.workspace.tabLayout == .sidebar ? ChromeView.sidebarWidth + inset : inset * 2
        let chromeH = coordinator.workspace.tabLayout == .sidebar ? inset * 2 : ChromeView.stripHeight + 6 + inset * 2
        let scale = window.backingScaleFactor
        let content = NSSize(width: size.width / scale + chromeW, height: size.height / scale + chromeH)
        window.setContentSize(content)
        window.center()
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) { persistFrame() }
    func windowDidMove(_ notification: Notification) { persistFrame() }

    func windowWillClose(_ notification: Notification) {
        coordinator.windowWillClose(state.id)
    }

    private func persistFrame() {
        guard let f = window?.frame else { return }
        state.frame = WindowFrame(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height)
        coordinator.modelDidChange()
    }
}
```

- [ ] **Step 5: WorkspaceCoordinator (first version: tabs, windows, titles, pwd, exit)**

`Sources/PrompTTYApp/WorkspaceCoordinator.swift`:

```swift
import AppKit
import GhosttyBridge
import WorkspaceModel

/// Owns the mapping between the model, window controllers, and surfaces, and is libghostty's action sink.
@MainActor
final class WorkspaceCoordinator: GhosttyActionSink {
    let runtime: GhosttyRuntime
    let workspace: Workspace
    private var controllers: [WindowID: TerminalWindowController] = [:]
    /// Set by Task 10 to schedule a session save.
    var onModelChanged: (() -> Void)?

    init(runtime: GhosttyRuntime, workspace: Workspace) {
        self.runtime = runtime
        self.workspace = workspace
    }

    /// Opens a controller for every window in the model; creates a default window if none.
    func start() {
        if workspace.windows.isEmpty {
            let w = workspace.addWindow()
            w.addTab(title: "", workingDirectory: NSHomeDirectory())
        }
        for state in workspace.windows {
            if state.isEmpty { state.addTab(title: "", workingDirectory: NSHomeDirectory()) }
            open(state)
        }
        controllers.values.first?.window?.makeKeyAndOrderFront(nil)
    }

    func controller(for id: WindowID) -> TerminalWindowController? { controllers[id] }

    func modelDidChange() { onModelChanged?() }

    // MARK: Mutations

    func newWindow(workingDirectory: String? = nil) {
        let state = workspace.addWindow()
        state.addTab(title: "", workingDirectory: workingDirectory ?? NSHomeDirectory())
        open(state)
        controllers[state.id]?.window?.makeKeyAndOrderFront(nil)
        modelDidChange()
    }

    func newTab(in state: WindowState, workingDirectory: String? = nil) {
        let dir = workingDirectory ?? state.selectedTab?.workingDirectory ?? NSHomeDirectory()
        state.addTab(title: "", workingDirectory: dir)
        controllers[state.id]?.reload()
        modelDidChange()
    }

    func select(_ id: TabID) {
        guard let state = workspace.window(containing: id) else { return }
        state.select(id: id)
        controllers[state.id]?.reload()
        modelDidChange()
    }

    /// Closes a tab; closing the last tab closes the window.
    func closeTab(_ id: TabID) {
        guard let state = workspace.window(containing: id), let controller = controllers[state.id] else { return }
        controller.removeSurface(for: id)
        state.closeTab(id: id)
        if state.isEmpty {
            controller.window?.close()
        } else {
            controller.reload()
        }
        modelDidChange()
    }

    func rename(_ id: TabID, to title: String) {
        guard let state = workspace.window(containing: id), let tab = state.tab(id: id) else { return }
        tab.customTitle = title
        controllers[state.id]?.reload()
        modelDidChange()
    }

    func move(_ id: TabID, to index: Int) {
        guard let state = workspace.window(containing: id) else { return }
        state.moveTab(id: id, to: index)
        controllers[state.id]?.reload()
        modelDidChange()
    }

    func toggleTabLayout() {
        workspace.toggleTabLayout()
        for c in controllers.values { c.setTabLayout(workspace.tabLayout, hidden: tabListHidden) }
        modelDidChange()
    }

    /// ⌘B. A preference, not session state, so it lives in UserDefaults.
    private static let tabListHiddenKey = "tabListHidden"
    var tabListHidden: Bool { UserDefaults.standard.bool(forKey: Self.tabListHiddenKey) }

    func toggleTabListHidden() {
        UserDefaults.standard.set(!tabListHidden, forKey: Self.tabListHiddenKey)
        for c in controllers.values { c.setTabLayout(workspace.tabLayout, hidden: tabListHidden) }
    }

    func windowWillClose(_ id: WindowID) {
        guard let controller = controllers.removeValue(forKey: id) else { return }
        for view in controller.allSurfaces() { view.teardown() }
        workspace.removeWindow(id: id)
        modelDidChange()
    }

    private func open(_ state: WindowState) {
        let controller = TerminalWindowController(state: state, coordinator: self, runtime: runtime)
        controllers[state.id] = controller
        controller.setTabLayout(workspace.tabLayout, hidden: tabListHidden)
        controller.reload()
        controller.showWindow(nil)
    }

    // MARK: Lookup

    private func locate(_ view: TerminalSurfaceView) -> (WindowState, Tab, TerminalWindowController)? {
        guard let id = view.token?.base as? TabID,
              let state = workspace.window(containing: id),
              let tab = state.tab(id: id),
              let controller = controllers[state.id] else { return nil }
        return (state, tab, controller)
    }

    private var keyWindowState: WindowState? {
        controllers.values.first { $0.window?.isKeyWindow == true }?.state ?? workspace.windows.first
    }

    // MARK: GhosttyActionSink

    func handle(_ action: GhosttyAction, target: GhosttyActionTarget) -> Bool {
        let located: (WindowState, Tab, TerminalWindowController)?
        if case .surface(let view) = target { located = locate(view) } else { located = nil }
        let state = located?.0 ?? keyWindowState

        switch action {
        case .newWindow:
            newWindow(workingDirectory: located?.1.workingDirectory)
            return true
        case .newTab:
            guard let state else { return false }
            newTab(in: state)
            return true
        case .closeTab(let mode):
            guard let state else { return false }
            let selected = located?.1.id ?? state.selectedTabID
            guard let selected else { return false }
            switch mode {
            case .this: closeTab(selected)
            case .others: state.tabs.map(\.id).filter { $0 != selected }.forEach(closeTab)
            case .right:
                guard let i = state.index(of: selected) else { return false }
                state.tabs.dropFirst(i + 1).map(\.id).forEach(closeTab)
            }
            return true
        case .closeWindow:
            guard let state else { return false }
            controllers[state.id]?.window?.close()
            return true
        case .quit:
            NSApp.terminate(nil)
            return true
        case .gotoTab(let g):
            guard let state else { return false }
            let target: GotoTabTarget
            switch g {
            case .index(let n): target = .index(n)
            case .previous: target = .previous
            case .next: target = .next
            case .last: target = .last
            }
            let moved = state.gotoTab(target)
            if moved { controllers[state.id]?.reload(); modelDidChange() }
            return moved
        case .moveTab(let amount):
            guard let state else { return false }
            let moved = state.moveSelectedTab(by: amount)
            if moved { controllers[state.id]?.reload(); modelDidChange() }
            return moved
        case .setTitle(let title), .setTabTitle(let title):
            guard let located else { return false }
            located.1.title = title
            located.2.reload()
            return true
        case .pwd(let dir):
            guard let located else { return false }
            located.1.workingDirectory = dir
            located.2.reload()
            modelDidChange()
            return true
        case .initialSize(let w, let h):
            guard let located else { return false }
            located.2.applyInitialTerminalSize(CGSize(width: Double(w), height: Double(h)))
            return true
        case .cellSize, .render, .configChange:
            return true
        case .colorChange(let kind, let r, let g, let b):
            guard kind == .background else { return true }
            let color = NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            let tint = ChromeTint.tint(forTerminalBackground: color)
            for c in controllers.values { c.chrome.tint = tint }
            return true
        case .showChildExited(let code, _):
            guard let located, case .surface(let view) = target else { return false }
            let tabID = located.1.id
            located.2.chrome.container.showExitedOverlay(for: view, exitCode: code) { [weak self] in
                self?.closeTab(tabID)
            }
            return true
        case .closeSurface:
            guard let located else { return false }
            closeTab(located.1.id)
            return true
        case .desktopNotification, .ringBell, .reloadConfig, .openConfig, .mouseShape, .mouseVisibility, .unhandled:
            // Notifications and bell are wired in Task 9; config actions are handled by the runtime.
            return false
        }
    }
}
```

Add to `TerminalWindowController` (it is referenced above; Task 8 gives it a real tab list):

```swift
    func setTabLayout(_ layout: TabLayout, hidden: Bool) {
        // Task 8 installs the real tab list here. For now, a placeholder spacer keeps the chrome layout honest.
        chrome.install(tabList: hidden ? nil : NSView(), layout: layout)
    }
```

- [ ] **Step 6: AppDelegate**

Replace `Sources/PrompTTYApp/AppDelegate.swift`:

```swift
import AppKit
import GhosttyBridge
import WorkspaceModel

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime!
    private var workspace: Workspace!
    private var coordinator: WorkspaceCoordinator!
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        do {
            runtime = try GhosttyRuntime()
        } catch {
            let alert = NSAlert()
            alert.messageText = "PrompTTY could not start the terminal engine"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        workspace = Workspace()
        coordinator = WorkspaceCoordinator(runtime: runtime, workspace: workspace)
        runtime.sink = coordinator
        syncColorScheme()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncColorScheme() }
        }
        coordinator.start()
        NSApp.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) { runtime?.setFocus(true) }
    func applicationDidResignActive(_ notification: Notification) { runtime?.setFocus(false) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func syncColorScheme() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        runtime.setColorScheme(dark: dark)
    }
}
```

Create a minimal `Sources/PrompTTYApp/MainMenu.swift` (Task 9 expands it):

```swift
import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit PrompTTY", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        return menu
    }
}
```

- [ ] **Step 7: Build and run; verify the terminal works**

Run: `./script/run`
Expected: a window with a tinted frame and a dark rounded terminal card. A shell prompt appears. Check each:
- Typing `echo hi` and Enter prints `hi`.
- `ls --color` shows colors; the font and theme come from `~/.config/ghostty/config` if present, otherwise Ghostty defaults.
- Resizing the window reflows the terminal; `tput cols` changes accordingly.
- Dragging the window to a display with a different scale keeps text crisp.
- Scrolling with the trackpad scrolls scrollback after `seq 1 500`.
- `exit` shows the "Process exited" overlay with a working Close tab button, which closes the window because it was the last tab.
- The Console app shows no `GHOSTTY_RESOURCES_DIR` warnings; `echo $TERM` prints `xterm-ghostty`.

If `$TERM` is not `xterm-ghostty`, the resources dir is wrong: log `GhosttyKitResources.directoryURL` at startup and confirm it contains `terminfo/`.

- [ ] **Step 8: Commit**

```bash
git add Sources/PrompTTYApp
git commit -m "feat(app): tinted chrome window hosting one libghostty surface per tab"
```

---

### Task 8: Tab list in sidebar and strip modes

**Files:**
- Create: `Sources/PrompTTYApp/Chrome/TabCollectionView.swift`
- Create: `Sources/PrompTTYApp/Chrome/TabItem.swift`
- Modify: `Sources/PrompTTYApp/Chrome/TerminalWindowController.swift` (`setTabLayout`, `reload`)

**Interfaces:**
- Consumes: `WindowState`, `Tab`, `TabID`, `TabLayout`; `WorkspaceCoordinator.select/closeTab/rename/move/newTab`.
- Produces:
  - `@MainActor protocol TabCollectionViewDelegate: AnyObject { func tabList(_: TabCollectionView, didSelect: TabID); func tabList(_: TabCollectionView, didRequestClose: TabID); func tabList(_: TabCollectionView, didRename: TabID, to: String); func tabList(_: TabCollectionView, didMove: TabID, to: Int); func tabListDidRequestNewTab(_: TabCollectionView) }`
  - `@MainActor final class TabCollectionView: NSView { init(layout: TabLayout); weak var delegate: TabCollectionViewDelegate?; func update(tabs: [Tab], selected: TabID?) }`
  - `final class TabItem: NSCollectionViewItem` and `final class NewTabItem: NSCollectionViewItem`.

- [ ] **Step 1: TabItem**

`Sources/PrompTTYApp/Chrome/TabItem.swift`:

```swift
import AppKit
import WorkspaceModel

@MainActor
protocol TabItemDelegate: AnyObject {
    func tabItemDidRequestClose(_ item: TabItem)
    func tabItem(_ item: TabItem, didRename title: String)
}

/// One tab row. In sidebar mode it shows title and directory; in strip mode only the title.
final class TabItem: NSCollectionViewItem, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("TabItem")

    weak var delegate: TabItemDelegate?
    private(set) var tabID: TabID?

    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")!, target: nil, action: nil)
    private var compact = false
    private var tracking: NSTrackingArea?

    override func loadView() {
        let root = HoverView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 7
        root.layer?.cornerCurve = .continuous
        root.onHover = { [weak self] hovering in self?.closeButton.isHidden = !hovering }
        view = root

        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.isEditable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.delegate = self
        subtitleField.font = .systemFont(ofSize: 10.5)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingMiddle

        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let labels = NSStackView(views: [titleField, subtitleField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let row = NSStackView(views: [labels, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 7)
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            row.topAnchor.constraint(equalTo: view.topAnchor),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(beginRename))
        doubleClick.numberOfClicksRequired = 2
        view.addGestureRecognizer(doubleClick)
    }

    func configure(tab: Tab, compact: Bool, selected: Bool) {
        tabID = tab.id
        self.compact = compact
        titleField.stringValue = tab.displayTitle
        subtitleField.stringValue = tab.abbreviatedDirectory
        subtitleField.isHidden = compact
        isSelected = selected
        applySelection()
    }

    override var isSelected: Bool {
        didSet { applySelection() }
    }

    private func applySelection() {
        view.layer?.backgroundColor = isSelected
            ? NSColor.white.withAlphaComponent(0.55).cgColor
            : NSColor.clear.cgColor
    }

    @objc private func closeTapped() { delegate?.tabItemDidRequestClose(self) }

    @objc private func beginRename() {
        titleField.isEditable = true
        titleField.isBordered = true
        titleField.drawsBackground = true
        view.window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        titleField.isEditable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        delegate?.tabItem(self, didRename: titleField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            titleField.abortEditing()
            titleField.isEditable = false
            titleField.isBordered = false
            titleField.drawsBackground = false
            view.window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

/// The trailing "+" item.
final class NewTabItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("NewTabItem")
    var onTap: (() -> Void)?

    override func loadView() {
        let button = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")!, target: self, action: #selector(tapped))
        button.isBordered = false
        button.imagePosition = .imageOnly
        view = button
    }

    @objc private func tapped() { onTap?() }
}

/// Reports mouse enter/exit so rows can reveal their close button.
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
```

- [ ] **Step 2: TabCollectionView**

`Sources/PrompTTYApp/Chrome/TabCollectionView.swift`:

```swift
import AppKit
import UniformTypeIdentifiers
import WorkspaceModel

@MainActor
protocol TabCollectionViewDelegate: AnyObject {
    func tabList(_ list: TabCollectionView, didSelect id: TabID)
    func tabList(_ list: TabCollectionView, didRequestClose id: TabID)
    func tabList(_ list: TabCollectionView, didRename id: TabID, to title: String)
    func tabList(_ list: TabCollectionView, didMove id: TabID, to index: Int)
    func tabListDidRequestNewTab(_ list: TabCollectionView)
}

/// One NSCollectionView that lays out vertically (sidebar) or horizontally (strip).
/// Drag-to-reorder works in both because the flow layout handles both scroll directions.
@MainActor
final class TabCollectionView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, TabItemDelegate {
    private static let dragType = NSPasteboard.PasteboardType("dev.promptty.tab-id")

    weak var delegate: TabCollectionViewDelegate?
    let layoutMode: TabLayout
    private let collection = NSCollectionView()
    private let scroll = NSScrollView()
    private var tabs: [Tab] = []
    private var selected: TabID?

    init(layout: TabLayout) {
        layoutMode = layout
        super.init(frame: .zero)
        let flow = NSCollectionViewFlowLayout()
        flow.scrollDirection = layout == .sidebar ? .vertical : .horizontal
        flow.minimumLineSpacing = 2
        flow.minimumInteritemSpacing = 2
        flow.sectionInset = layout == .sidebar ? NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8) : NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        collection.collectionViewLayout = flow
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsEmptySelection = false
        collection.backgroundColors = [.clear]
        collection.register(TabItem.self, forItemWithIdentifier: TabItem.identifier)
        collection.register(NewTabItem.self, forItemWithIdentifier: NewTabItem.identifier)
        collection.registerForDraggedTypes([Self.dragType])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)

        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = layout == .sidebar
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(tabs: [Tab], selected: TabID?) {
        self.tabs = tabs
        self.selected = selected
        collection.reloadData()
        if let selected, let i = tabs.firstIndex(where: { $0.id == selected }) {
            collection.selectionIndexPaths = [IndexPath(item: i, section: 0)]
        }
    }

    override func layout() {
        super.layout()
        collection.collectionViewLayout?.invalidateLayout()
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { tabs.count + 1 }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        if indexPath.item == tabs.count {
            let item = collectionView.makeItem(withIdentifier: NewTabItem.identifier, for: indexPath) as! NewTabItem
            item.onTap = { [weak self] in
                guard let self else { return }
                self.delegate?.tabListDidRequestNewTab(self)
            }
            return item
        }
        let item = collectionView.makeItem(withIdentifier: TabItem.identifier, for: indexPath) as! TabItem
        let tab = tabs[indexPath.item]
        item.delegate = self
        item.configure(tab: tab, compact: layoutMode == .strip, selected: tab.id == selected)
        return item
    }

    // MARK: Layout

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let isNewTab = indexPath.item == tabs.count
        switch layoutMode {
        case .sidebar:
            let w = max(1, bounds.width - 16)
            return NSSize(width: w, height: isNewTab ? 28 : 42)
        case .strip:
            return NSSize(width: isNewTab ? 28 : 150, height: 28)
        }
    }

    // MARK: Selection

    func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        indexPaths.filter { $0.item < tabs.count }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first, ip.item < tabs.count else { return }
        delegate?.tabList(self, didSelect: tabs[ip.item].id)
    }

    // MARK: Drag to reorder

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        indexPaths.allSatisfy { $0.item < tabs.count }
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < tabs.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(tabs[indexPath.item].id.rawValue.uuidString, forType: Self.dragType)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        dropOperation.pointee = .before
        if proposedIndexPath.pointee.item > tabs.count {
            proposedIndexPath.pointee = NSIndexPath(forItem: tabs.count, inSection: 0)
        }
        return .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let raw = draggingInfo.draggingPasteboard.string(forType: Self.dragType),
              let uuid = UUID(uuidString: raw) else { return false }
        let id = TabID(rawValue: uuid)
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return false }
        var to = min(indexPath.item, tabs.count)
        if to > from { to -= 1 }
        delegate?.tabList(self, didMove: id, to: to)
        return true
    }

    // MARK: TabItemDelegate

    func tabItemDidRequestClose(_ item: TabItem) {
        guard let id = item.tabID else { return }
        delegate?.tabList(self, didRequestClose: id)
    }

    func tabItem(_ item: TabItem, didRename title: String) {
        guard let id = item.tabID else { return }
        delegate?.tabList(self, didRename: id, to: title)
    }
}
```

- [ ] **Step 3: Wire into TerminalWindowController**

Replace the placeholder `setTabLayout` and extend `reload` in `TerminalWindowController.swift`:

```swift
    private var tabList: TabCollectionView?

    func setTabLayout(_ layout: TabLayout, hidden: Bool) {
        guard !hidden else {
            tabList = nil
            chrome.install(tabList: nil, layout: layout)
            return
        }
        let list = TabCollectionView(layout: layout)
        list.delegate = self
        tabList = list
        chrome.install(tabList: list, layout: layout)
        reload()
    }
```

and in `reload()` add after the `guard`:

```swift
        tabList?.update(tabs: state.tabs, selected: state.selectedTabID)
```

Add the delegate conformance at the bottom of the file:

```swift
extension TerminalWindowController: TabCollectionViewDelegate {
    func tabList(_ list: TabCollectionView, didSelect id: TabID) { coordinator.select(id) }
    func tabList(_ list: TabCollectionView, didRequestClose id: TabID) { coordinator.closeTab(id) }
    func tabList(_ list: TabCollectionView, didRename id: TabID, to title: String) { coordinator.rename(id, to: title) }
    func tabList(_ list: TabCollectionView, didMove id: TabID, to index: Int) { coordinator.move(id, to: index) }
    func tabListDidRequestNewTab(_ list: TabCollectionView) { coordinator.newTab(in: state) }
}
```

- [ ] **Step 4: Build and verify both layouts**

Run: `./script/run`
Expected, sidebar mode (default):
- The sidebar lists one tab with title and `~`-abbreviated directory; traffic lights sit above it with nothing underneath them.
- "+" adds a tab in the same directory; `cd /tmp` updates the subtitle within a second (OSC 7 needs shell integration, which `xterm-ghostty` + Ghostty's injected integration provide for zsh, bash, fish).
- Clicking a tab switches instantly and focus lands in the terminal (typing works without clicking the card).
- Hovering a row reveals ×; clicking it closes that tab.
- Double-clicking a title edits it; Enter commits, Escape cancels; the renamed title persists after title changes from the shell.
- Dragging a row above another reorders.

Then temporarily add `coordinator.toggleTabLayout()` as the last line of `AppDelegate.applicationDidFinishLaunching`, rerun, and check strip mode: tabs run horizontally to the right of the traffic lights, titles only, "+" at the end, drag reorders horizontally. Remove the temporary line.

- [ ] **Step 5: Commit**

```bash
git add Sources/PrompTTYApp
git commit -m "feat(app): tab list as sidebar or strip with select, close, rename, and drag reorder"
```

---

### Task 9: Menus, commands, banner, notifications, bell

**Files:**
- Modify: `Sources/PrompTTYApp/MainMenu.swift`
- Modify: `Sources/PrompTTYApp/Chrome/TerminalWindowController.swift` (responder actions)
- Modify: `Sources/PrompTTYApp/WorkspaceCoordinator.swift` (notification, bell, banner)
- Modify: `Sources/PrompTTYApp/AppDelegate.swift` (toggle layout, new window, config diagnostics)
- Create: `Sources/PrompTTYApp/Chrome/BannerView.swift`

**Interfaces:**
- Produces: `@MainActor final class BannerView: NSView { init(message: String, actionTitle: String?, action: (() -> Void)?) }`
- Produces responder actions on `TerminalWindowController`: `newTab(_:)`, `closeTab(_:)`, `previousTab(_:)`, `nextTab(_:)`, `toggleTabLayout(_:)`; and on `AppDelegate`: `newWindow(_:)`, `toggleTabLayout(_:)`, `reloadConfig(_:)`, `openConfig(_:)`.

- [ ] **Step 1: BannerView**

`Sources/PrompTTYApp/Chrome/BannerView.swift`:

```swift
import AppKit

/// Non-modal message strip above the terminal card.
@MainActor
final class BannerView: NSView {
    private var handler: ClosureTarget?

    init(message: String, actionTitle: String?, action: (() -> Void)?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [label, NSView()]
        if let actionTitle, let action {
            let button = NSButton(title: actionTitle, target: nil, action: nil)
            button.bezelStyle = .inline
            button.controlSize = .small
            let target = ClosureTarget(action)
            button.target = target
            button.action = #selector(ClosureTarget.fire)
            handler = target
            views.append(button)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
```

- [ ] **Step 2: Full menu bar**

Replace `Sources/PrompTTYApp/MainMenu.swift`:

```swift
import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let menu = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About PrompTTY", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Reload Configuration", action: #selector(AppDelegate.reloadConfig(_:)), keyEquivalent: ",").keyEquivalentModifierMask = [.command, .shift]
        app.addItem(withTitle: "Open Configuration", action: #selector(AppDelegate.openConfig(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide PrompTTY", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit PrompTTY", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(submenu: app, title: "PrompTTY")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "New Tab", action: #selector(TerminalWindowController.newTab(_:)), keyEquivalent: "t")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(TerminalWindowController.closeTab(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w").keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(submenu: file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Tab Layout", action: #selector(AppDelegate.toggleTabLayout(_:)), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
        view.addItem(withTitle: "Hide Tab List", action: #selector(AppDelegate.toggleTabListHidden(_:)), keyEquivalent: "b")
        view.addItem(.separator())
        view.addItem(withTitle: "Previous Tab", action: #selector(TerminalWindowController.previousTab(_:)), keyEquivalent: "[").keyEquivalentModifierMask = [.command, .shift]
        view.addItem(withTitle: "Next Tab", action: #selector(TerminalWindowController.nextTab(_:)), keyEquivalent: "]").keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        menu.addItem(submenu: view, title: "View")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        menu.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        return menu
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
```

Note on ⌘C/⌘V: Ghostty's default keybinds `super+c` / `super+v` are handled inside libghostty via `ghostty_surface_key`, which runs before the menu because the surface is first responder and consumes them. The Edit menu items exist for discoverability and for text fields such as tab rename. Leave `NSText` selectors as is.

- [ ] **Step 3: Responder actions**

Append to `TerminalWindowController`:

```swift
    // MARK: Menu actions (responder chain)

    @objc func newTab(_ sender: Any?) { coordinator.newTab(in: state) }

    @objc func closeTab(_ sender: Any?) {
        guard let id = state.selectedTabID else { return }
        coordinator.closeTab(id)
    }

    @objc func previousTab(_ sender: Any?) {
        if state.gotoTab(.previous) { reload(); coordinator.modelDidChange() }
    }

    @objc func nextTab(_ sender: Any?) {
        if state.gotoTab(.next) { reload(); coordinator.modelDidChange() }
    }
```

Append to `AppDelegate`:

```swift
    @objc func newWindow(_ sender: Any?) { coordinator.newWindow() }
    @objc func toggleTabLayout(_ sender: Any?) { coordinator.toggleTabLayout() }
    @objc func toggleTabListHidden(_ sender: Any?) { coordinator.toggleTabListHidden() }
    @objc func reloadConfig(_ sender: Any?) { runtime.reloadConfig() }
    @objc func openConfig(_ sender: Any?) { runtime.openConfig() }
```

- [ ] **Step 4: Config diagnostics banner**

In `AppDelegate.applicationDidFinishLaunching`, after `runtime.sink = coordinator`:

```swift
        runtime.onConfigDiagnostics = { [weak self] diags in self?.coordinator.showConfigDiagnostics(diags) }
        coordinator.showConfigDiagnostics(runtime.configDiagnostics)
```

Add to `WorkspaceCoordinator`:

```swift
    private var configBannerMessage: String?

    func showConfigDiagnostics(_ diagnostics: [String]) {
        configBannerMessage = diagnostics.isEmpty ? nil : "Ghostty config: \(diagnostics[0])" + (diagnostics.count > 1 ? " (+\(diagnostics.count - 1) more)" : "")
        for c in controllers.values { applyBanner(to: c) }
    }

    private func applyBanner(to controller: TerminalWindowController) {
        guard let message = configBannerMessage else {
            controller.chrome.setBanner(nil)
            return
        }
        controller.chrome.setBanner(BannerView(message: message, actionTitle: "Open config") { [weak self] in
            self?.runtime.openConfig()
        })
    }
```

and call `applyBanner(to: controller)` inside `open(_:)` right after `controller.setTabLayout(...)`.

Also surface-creation failures: in `AppDelegate` after creating the coordinator:

```swift
        runtime.onSurfaceCreationFailed = { [weak self] view in
            guard let id = view.token?.base as? TabID else { return }
            self?.coordinator.closeTab(id)
            self?.coordinator.showTransientBanner("Could not start a terminal for that tab.")
        }
```

and in the coordinator:

```swift
    func showTransientBanner(_ message: String) {
        for c in controllers.values {
            c.chrome.setBanner(BannerView(message: message, actionTitle: nil, action: nil))
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self else { return }
            for c in self.controllers.values { self.applyBanner(to: c) }
        }
    }
```

- [ ] **Step 5: Desktop notifications and bell**

In `WorkspaceCoordinator.handle`, replace the final `case` with:

```swift
        case .desktopNotification(let title, let body):
            Notifications.post(title: title.isEmpty ? "PrompTTY" : title, body: body)
            return true
        case .ringBell:
            NSSound.beep()
            return true
        case .reloadConfig, .openConfig, .mouseShape, .mouseVisibility, .unhandled:
            return false
```

Create `Sources/PrompTTYApp/Notifications.swift`:

```swift
import UserNotifications

enum Notifications {
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
}
```

UNUserNotificationCenter requires a bundled app with a bundle identifier; the XcodeGen target provides one.

- [ ] **Step 6: Build and verify**

Run: `./script/run`
Check:
- ⌘T opens a tab in the current directory; ⌘W closes it; closing the last tab closes the window; ⌘N opens a new window; the app keeps running with no windows and ⌘N works again.
- ⇧⌘[ and ⇧⌘] cycle tabs with wrap-around; Ghostty's own `super+shift+left_bracket` keybind (if the user has it) produces the same result through `GhosttyAction.gotoTab`.
- ⌃⌘S toggles sidebar/strip live in every open window. ⌘B hides the tab list so the card fills the window; ⌘B again restores it, and the choice survives relaunch.
- Put a bad line such as `font-size = banana` in `~/.config/ghostty/config`, press ⇧⌘, (Reload Configuration): a yellow banner appears with "Open config"; fix the line, reload, banner disappears.
- `printf '\a'` beeps. `printf '\e]9;Hello from the shell\a'` posts a notification (grant permission once).

- [ ] **Step 7: Commit**

```bash
git add Sources/PrompTTYApp
git commit -m "feat(app): menu bar, keyboard commands, config banner, notifications and bell"
```

---

### Task 10: Session restore and save

**Files:**
- Modify: `Sources/PrompTTYApp/AppDelegate.swift`
- Modify: `Sources/PrompTTYApp/WorkspaceCoordinator.swift`

**Interfaces:**
- Consumes: `SessionStore`, `SessionSnapshot`, `Workspace.snapshot()`, `Workspace.restore(from:)`, `DebouncedSaver` (Task 3); `WorkspaceCoordinator.onModelChanged` (Task 7).

- [ ] **Step 1: Restore at launch**

In `AppDelegate`, replace `workspace = Workspace()` with:

```swift
        let store = SessionStore(url: SessionStore.defaultURL)
        sessionStore = store
        if let snapshot = store.load() {
            workspace = Workspace.restore(from: snapshot)
        } else {
            workspace = Workspace()
        }
```

Add stored properties:

```swift
    private var sessionStore: SessionStore!
    private var saver: DebouncedSaver!
```

- [ ] **Step 2: Debounced save on every model change, flush on quit**

After `coordinator = WorkspaceCoordinator(...)`:

```swift
        saver = DebouncedSaver(delay: .seconds(1)) { [weak self] in self?.saveSession() }
        coordinator.onModelChanged = { [weak self] in self?.saver.schedule() }
```

Add:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        saver?.flush()
        saveSession()
    }

    private func saveSession() {
        do {
            try sessionStore.save(workspace.snapshot())
        } catch {
            NSLog("PrompTTY: could not save session: \(error)")
        }
    }
```

- [ ] **Step 3: Confirm-quit guard**

Add to `AppDelegate`:

```swift
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard runtime.needsConfirmQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit PrompTTY?"
        alert.informativeText = "A process is still running in one of your tabs."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
```

- [ ] **Step 4: Verify**

Run: `./script/run`
- Open three tabs in different directories, rename one, switch to strip mode, move the window, quit with ⌘Q.
- Inspect `~/Library/Application Support/PrompTTY/session.json`: three tabs, `customTitle`, `"tabLayout": "strip"`, a `frame`.
- Relaunch: same window position, strip mode, three tabs with their directories and the custom title, same selected tab. Scrollback is empty (expected).
- Corrupt the file (`echo garbage > .../session.json`), relaunch: one tab in `$HOME`, a `session.json.bak` exists.
- Start `sleep 1000` in a tab, press ⌘Q: the confirm dialog appears; Cancel keeps the app running.

- [ ] **Step 5: Commit**

```bash
git add Sources/PrompTTYApp
git commit -m "feat(app): restore tabs, directories, layout and window frames across launches"
```

---

### Task 11: README, acceptance pass, and tidy

**Files:**
- Create: `README.md`
- Modify: `script/test` (also build the app so CI-style checks catch AppKit compile errors)

- [ ] **Step 1: README**

`README.md`:

```markdown
# PrompTTY 2

A native macOS terminal built on [libghostty](https://ghostty.org), the engine behind Ghostty,
with tabs in a sidebar or a strip and chrome tinted from your Ghostty theme. It reads your
existing `~/.config/ghostty/config` and never writes to it.

This is the MVP of a larger agent-workspace project. See `docs/superpowers/specs/` for the design.

## Build

Requires Xcode 26 or newer and macOS 15 or newer. No Zig: libghostty arrives as a prebuilt
xcframework through SwiftPM.

    ./script/bootstrap   # installs xcodegen if needed, resolves packages, generates the Xcode project
    ./script/run         # builds Debug and launches the app
    ./script/test        # runs the library tests

## Shortcuts

| Action | Keys |
|---|---|
| New tab / close tab | ⌘T / ⌘W |
| New window | ⌘N |
| Previous / next tab | ⇧⌘[ / ⇧⌘] |
| Toggle sidebar / strip | ⌃⌘S |
| Hide / show tab list | ⌘B |
| Reload / open Ghostty config | ⇧⌘, / ⌘, |

Ghostty keybinds from your config (for example `goto_tab`, `new_tab`, `move_tab`) also work.

## Layout

    Sources/WorkspaceModel   tabs, windows, session JSON (no AppKit)
    Sources/GhosttyBridge    the only code that touches libghostty
    Sources/PrompTTYApp      AppKit chrome, menus, coordinator
```

- [ ] **Step 2: script/test also compiles the app**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test
[ -d PrompTTY.xcodeproj ] || xcodegen generate
xcodebuild -project PrompTTY.xcodeproj -scheme PrompTTYApp -configuration Debug \
  -derivedDataPath .build/DerivedData build -quiet
echo "OK"
```

- [ ] **Step 3: Run the full acceptance checklist and record results**

Run `./script/test`, then `./script/run`, and work through the spec's manual acceptance list. Record the outcome of each line below in the commit message body as PASS or FAIL with a note; do not mark the task done with any FAIL.

1. Launch with no session file: one window, one tab in `$HOME`, prompt visible.
2. Three tabs; `echo`, `vim` (open, edit, `:q!`), and `yazi` or `htop` if installed render and respond to arrows.
3. Resize the window; `tput cols; tput lines` reflect it.
4. Move the window between a Retina and non-Retina display if available; text stays crisp.
5. ⌃⌘S toggles layout; all features (select, close, rename, reorder, +) work in both.
6. Rename a tab; `cd` elsewhere; the subtitle updates, the custom title stays.
7. Quit and relaunch: tabs, directories, custom title, layout, selection, frame restored.
8. With `~/.config/ghostty/config` setting `font-family` and `theme`, both apply; `background` color changes the chrome tint.
9. `exit` in a tab shows the exited overlay; Close tab works; last tab closes the window.
10. ⌘Q with a running `sleep` asks for confirmation.

- [ ] **Step 4: Commit**

```bash
git add README.md script/test
git commit -m "docs: README with build steps and shortcuts; test script also compiles the app"
```
