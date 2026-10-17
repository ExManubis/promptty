import Foundation

public struct TabSnapshot: Codable, Equatable, Sendable {
    public var title: String
    public var customTitle: String?
    public var workingDirectory: String
    /// Absent in session files written before pinned tabs.
    public var pin: TabPin?
    /// Absent in session files written before projects, and for a tab in none.
    public var project: ProjectID?
    /// The file (`ScrollbackArchive`) with what the tab's focused pane showed; absent when none was
    /// kept.
    public var scrollback: String?
    /// The focused pane's label; absent when it has none.
    public var label: String?
    /// The panes, for a tab split into several: each one's folder, label and scrollback file.
    /// Absent for a tab with one pane, and in session files written before splits were kept
    /// (whose tabs come back with the focused pane alone, as described by the fields above).
    public var layout: ClosedLayout?
    public init(title: String, customTitle: String?, workingDirectory: String, pin: TabPin? = nil, project: ProjectID? = nil,
                scrollback: String? = nil, label: String? = nil, layout: ClosedLayout? = nil) {
        self.title = title; self.customTitle = customTitle; self.workingDirectory = workingDirectory; self.pin = pin
        self.project = project; self.scrollback = scrollback; self.label = label; self.layout = layout
    }
}

/// A `directory` written by early builds, when projects had folders, is ignored.
public struct ProjectSnapshot: Codable, Equatable, Sendable {
    public var id: ProjectID
    public var name: String
    public var icon: PinIcon?
    public var folded: Bool
    public init(id: ProjectID, name: String, icon: PinIcon? = nil, folded: Bool = false) {
        self.id = id; self.name = name; self.icon = icon; self.folded = folded
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
    /// Projects did not change it: they are fields older versions ignore, so a session written
    /// now still opens in an older build (without its projects).
    public static let currentVersion = 1
    public var version: Int
    public var tabLayout: TabLayout
    public var projects: [ProjectSnapshot]
    public var windows: [WindowSnapshot]
    public init(version: Int, tabLayout: TabLayout, projects: [ProjectSnapshot] = [], windows: [WindowSnapshot]) {
        self.version = version; self.tabLayout = tabLayout; self.projects = projects; self.windows = windows
    }

    private enum CodingKeys: String, CodingKey { case version, tabLayout, projects, windows }

    /// `projects` is absent in session files written before projects.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        tabLayout = try c.decode(TabLayout.self, forKey: .tabLayout)
        projects = try c.decodeIfPresent([ProjectSnapshot].self, forKey: .projects) ?? []
        windows = try c.decode([WindowSnapshot].self, forKey: .windows)
    }
}

extension Workspace {
    /// `scrollback`: the archive file kept for a pane, if any.
    public func snapshot(scrollback: (Pane) -> String? = { _ in nil }) -> SessionSnapshot {
        SessionSnapshot(
            version: SessionSnapshot.currentVersion,
            tabLayout: tabLayout,
            projects: projects.map { ProjectSnapshot(id: $0.id, name: $0.name, icon: $0.icon, folded: $0.folded) },
            windows: windows.map { w in
                WindowSnapshot(
                    frame: w.frame,
                    tabs: w.tabs.map { TabSnapshot(title: $0.title, customTitle: $0.customTitle, workingDirectory: $0.workingDirectory, pin: $0.pin, project: w.project(of: $0), scrollback: scrollback($0.focusedPane),
                                                label: $0.focusedPane.label, layout: $0.hasSplits ? $0.layout(scrollback: scrollback) : nil) },
                    selectedIndex: w.selectedTabID.flatMap(w.index(of:))
                )
            }
        )
    }

    /// Rebuilds a workspace. Working directories that are no longer directories fall back to
    /// `fallbackDirectory`. A split tab comes back split; a pinned tab opens as its pin: one pane in
    /// its pinned folder, running its command there.
    /// Projects come back as they were; a tab naming a project the file does not have is in none. Windows without tabs are skipped; if none remain, the result
    /// is one window with one tab so the app never launches without a terminal.
    public static func restore(
        from snapshot: SessionSnapshot,
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        },
        fallbackDirectory: String = NSHomeDirectory()
    ) -> Workspace {
        let ws = Workspace(tabLayout: snapshot.tabLayout)
        for p in snapshot.projects where ws.project(id: p.id) == nil {
            ws.addProject(name: p.name, icon: p.icon, id: p.id, folded: p.folded)
        }
        for windowSnap in snapshot.windows where !windowSnap.tabs.isEmpty {
            let w = ws.addWindow(frame: windowSnap.frame)
            var restored: [Tab] = []
            for t in windowSnap.tabs {
                let wanted = t.pin?.directory ?? t.workingDirectory
                let exists = directoryExists(wanted)
                let project = t.project.flatMap { ws.project(id: $0) }?.id
                // Nothing selected: each tab goes last in its group, so the saved order holds
                // within each group (a session from a build with a flat list is regrouped).
                w.selectedTabID = nil
                let tab = w.addTab(title: t.title, workingDirectory: exists ? wanted : fallbackDirectory, customTitle: t.customTitle, project: project)
                if let layout = t.layout, t.pin == nil {
                    tab.restore(layout) { directoryExists($0) ? $0 : fallbackDirectory }
                    tab.focusedPane.title = t.title
                } else {
                    tab.focusedPane.restoredScrollback = t.scrollback
                    tab.focusedPane.label = t.label.flatMap(Pane.label)
                }
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
