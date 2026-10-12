import Foundation

public enum CursorStyle: String, Codable, CaseIterable, Sendable {
    case block, bar, underline
}

public enum OptionAsAlt: String, Codable, CaseIterable, Sendable {
    case both, left, right, off
}

public enum NewTabDirectory: String, Codable, CaseIterable, Sendable {
    case currentPane, home
}

/// Where the tab list lives. Mirrors `WorkspaceModel.TabLayout`; the app maps between them.
public enum TabLayoutSetting: String, Codable, CaseIterable, Sendable {
    case sidebar, strip
}

/// Everything the user can change in Settings. Decoding tolerates missing keys, unknown enum
/// values and out-of-range numbers: each falls back to its default or is clamped.
public struct Settings: Equatable, Sendable {
    public static let currentVersion = 1
    public static let fontSizeRange: ClosedRange<Double> = 6...72
    public static let sidebarWidthRange: ClosedRange<Double> = 180...320

    public var version = Settings.currentVersion

    // Appearance
    public var fontFamily = "SF Mono"
    public var fontSize: Double = 13
    public var followSystemAppearance = true
    public var lightTheme = "Flexoki Light"
    public var darkTheme = "Flexoki Dark"
    /// Used when `followSystemAppearance` is off.
    public var theme = "Flexoki Dark"
    public var cursorStyle = CursorStyle.block
    public var cursorBlink = true
    /// 0…1: how strongly the window backdrop follows the theme background. 0 is the system's
    /// neutral window color (the Dia-style default).
    public var tintStrength: Double = 0

    // Tabs & windows
    public var tabLayout = TabLayoutSetting.sidebar
    public var sidebarWidth: Double = 220
    public var tabListHidden = false
    public var newTabDirectory = NewTabDirectory.currentPane
    public var restoreSession = true
    public var confirmCloseRunning = true

    // Keyboard
    public var optionAsAlt = OptionAsAlt.both
    /// `ShortcutAction.rawValue` → shortcut, only for actions that differ from the defaults.
    public var shortcuts: [String: Shortcut] = [:]

    public init() {}

    public func normalized() -> Settings {
        var s = self
        s.fontSize = min(Self.fontSizeRange.upperBound, max(Self.fontSizeRange.lowerBound, fontSize))
        s.sidebarWidth = min(Self.sidebarWidthRange.upperBound, max(Self.sidebarWidthRange.lowerBound, sidebarWidth))
        s.tintStrength = min(1, max(0, tintStrength))
        return s
    }

    /// First launch with no settings file: carry over what the MVP kept elsewhere.
    public static func migrated(tabLayout: TabLayoutSetting?, tabListHidden: Bool) -> Settings {
        var s = Settings()
        if let tabLayout { s.tabLayout = tabLayout }
        s.tabListHidden = tabListHidden
        return s
    }
}

extension Settings: Codable {
    enum CodingKeys: String, CodingKey {
        case version, fontFamily, fontSize, followSystemAppearance, lightTheme, darkTheme, theme
        case cursorStyle, cursorBlink, tintStrength, tabLayout, sidebarWidth, tabListHidden
        case newTabDirectory, restoreSession, confirmCloseRunning, optionAsAlt, shortcuts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = Settings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        s.version = value(.version, s.version)
        s.fontFamily = value(.fontFamily, s.fontFamily)
        s.fontSize = value(.fontSize, s.fontSize)
        s.followSystemAppearance = value(.followSystemAppearance, s.followSystemAppearance)
        s.lightTheme = value(.lightTheme, s.lightTheme)
        s.darkTheme = value(.darkTheme, s.darkTheme)
        s.theme = value(.theme, s.theme)
        s.cursorStyle = value(.cursorStyle, s.cursorStyle)
        s.cursorBlink = value(.cursorBlink, s.cursorBlink)
        s.tintStrength = value(.tintStrength, s.tintStrength)
        s.tabLayout = value(.tabLayout, s.tabLayout)
        s.sidebarWidth = value(.sidebarWidth, s.sidebarWidth)
        s.tabListHidden = value(.tabListHidden, s.tabListHidden)
        s.newTabDirectory = value(.newTabDirectory, s.newTabDirectory)
        s.restoreSession = value(.restoreSession, s.restoreSession)
        s.confirmCloseRunning = value(.confirmCloseRunning, s.confirmCloseRunning)
        s.optionAsAlt = value(.optionAsAlt, s.optionAsAlt)
        // Decode shortcuts one by one so a single bad entry does not drop the rest.
        if let raw = try? c.decodeIfPresent([String: String].self, forKey: .shortcuts) {
            s.shortcuts = raw.compactMapValues(Shortcut.init(string:))
        }
        self = s.normalized()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(fontFamily, forKey: .fontFamily)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(followSystemAppearance, forKey: .followSystemAppearance)
        try c.encode(lightTheme, forKey: .lightTheme)
        try c.encode(darkTheme, forKey: .darkTheme)
        try c.encode(theme, forKey: .theme)
        try c.encode(cursorStyle, forKey: .cursorStyle)
        try c.encode(cursorBlink, forKey: .cursorBlink)
        try c.encode(tintStrength, forKey: .tintStrength)
        try c.encode(tabLayout, forKey: .tabLayout)
        try c.encode(sidebarWidth, forKey: .sidebarWidth)
        try c.encode(tabListHidden, forKey: .tabListHidden)
        try c.encode(newTabDirectory, forKey: .newTabDirectory)
        try c.encode(restoreSession, forKey: .restoreSession)
        try c.encode(confirmCloseRunning, forKey: .confirmCloseRunning)
        try c.encode(optionAsAlt, forKey: .optionAsAlt)
        try c.encode(shortcuts, forKey: .shortcuts)
    }
}
