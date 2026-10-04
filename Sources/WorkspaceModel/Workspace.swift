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
