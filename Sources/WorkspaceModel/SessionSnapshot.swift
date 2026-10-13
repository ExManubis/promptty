import Foundation

public struct TabSnapshot: Codable, Equatable, Sendable {
    public var title: String
    public var customTitle: String?
    public var workingDirectory: String
    /// Absent in session files written before pinned tabs.
    public var pin: TabPin?
    public init(title: String, customTitle: String?, workingDirectory: String, pin: TabPin? = nil) {
        self.title = title; self.customTitle = customTitle; self.workingDirectory = workingDirectory; self.pin = pin
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
                    tabs: w.tabs.map { TabSnapshot(title: $0.title, customTitle: $0.customTitle, workingDirectory: $0.workingDirectory, pin: $0.pin) },
                    selectedIndex: w.selectedTabID.flatMap(w.index(of:))
                )
            }
        )
    }

    /// Rebuilds a workspace. Working directories that are no longer directories fall back to
    /// `fallbackDirectory`. A pinned tab opens in its pinned folder and runs its command there. Windows without tabs are skipped; if none remain, the result is one
    /// window with one tab so the app never launches without a terminal.
    public static func restore(
        from snapshot: SessionSnapshot,
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        },
        fallbackDirectory: String = NSHomeDirectory()
    ) -> Workspace {
        let ws = Workspace(tabLayout: snapshot.tabLayout)
        for windowSnap in snapshot.windows where !windowSnap.tabs.isEmpty {
            let w = ws.addWindow(frame: windowSnap.frame)
            var restored: [Tab] = []
            for t in windowSnap.tabs {
                let wanted = t.pin?.directory ?? t.workingDirectory
                let exists = directoryExists(wanted)
                let tab = w.addTab(title: t.title, workingDirectory: exists ? wanted : fallbackDirectory, customTitle: t.customTitle)
                if let pin = t.pin {
                    w.pin(tab.id, pin)
                    if exists { tab.focusedPane.startupCommand = pin.command }
                }
                restored.append(tab)
            }
            if let i = windowSnap.selectedIndex, i >= 0, i < restored.count {
                w.select(id: restored[i].id)
            } else if let first = w.tabs.first {
                w.select(id: first.id)
            }
        }
        if ws.windows.isEmpty {
            ws.addWindow().addTab(title: "", workingDirectory: fallbackDirectory)
        }
        return ws
    }
}
