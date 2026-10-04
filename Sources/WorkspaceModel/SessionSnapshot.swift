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
