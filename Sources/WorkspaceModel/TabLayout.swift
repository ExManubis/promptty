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
