import Foundation

public enum CursorStyle: String, Codable, CaseIterable, Sendable {
    case block, bar, underline
}

public enum OptionAsAlt: String, Codable, CaseIterable, Sendable {
    case both, left, right, off
}

/// What a program may do with the clipboard (OSC 52): libghostty's `clipboard-read`/`clipboard-write`.
public enum ClipboardAccess: String, Codable, CaseIterable, Sendable {
    case ask, allow, deny
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
    /// 2: Frame color default moved from 0.5 to 0 (neutral, Dia-style).
    public static let currentVersion = 2
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
    public var cursorColor = CursorColor.theme
    /// Keeps a ProMotion display at its full refresh rate while a PrompTTY window is in front,
    /// so a keystroke's frame shows within one 120 Hz refresh. Off by default: battery.
    public var fullRefreshRate = false
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

    // Notifications
    /// A command that ran at least `notifyAfterSeconds` and finished where the user was not
    /// looking posts a notification.
    public var notifyCommands = true
    public var notifyAfterSeconds: Double = 10
    public static let notifyAfterRange: ClosedRange<Double> = 3...3600

    // Keyboard
    public var optionAsAlt = OptionAsAlt.both
    /// ⌥H/J/K/L focus panes and ⌥⇧J/K switch tabs (`VimNavigation`), taken from the terminal.
    public var vimNavigation = true
    /// Forces macOS secure keyboard entry on while PrompTTY is in front (programs asking for it,
    /// as at a password prompt, get it regardless).
    public var secureKeyboardEntry = false

    // Programs
    /// Whether a program may read the clipboard (OSC 52), and write to it.
    public var clipboardRead = ClipboardAccess.ask
    public var clipboardWrite = ClipboardAccess.ask
    /// Programs (`Program.id`) that read, or write, without asking while the access above is
    /// "ask": the banner's "Always allow for <program>".
    public var clipboardReadPrograms: Set<String> = []
    public var clipboardWritePrograms: Set<String> = []
    /// `ShortcutAction.rawValue` → shortcut, only for actions that differ from the defaults.
    public var shortcuts: [String: Shortcut] = [:]

    public init() {}

    public func normalized() -> Settings {
        var s = self
        s.fontSize = min(Self.fontSizeRange.upperBound, max(Self.fontSizeRange.lowerBound, fontSize))
        s.sidebarWidth = min(Self.sidebarWidthRange.upperBound, max(Self.sidebarWidthRange.lowerBound, sidebarWidth))
        s.tintStrength = min(1, max(0, tintStrength))
        s.notifyAfterSeconds = min(Self.notifyAfterRange.upperBound, max(Self.notifyAfterRange.lowerBound, notifyAfterSeconds))
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
        case cursorStyle, cursorBlink, cursorColor, fullRefreshRate, tintStrength, tabLayout, sidebarWidth, tabListHidden
        case newTabDirectory, restoreSession, confirmCloseRunning, optionAsAlt, vimNavigation, secureKeyboardEntry, shortcuts
        case clipboardRead, clipboardWrite, clipboardReadPrograms, clipboardWritePrograms
        case notifyCommands, notifyAfterSeconds
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
        s.cursorColor = value(.cursorColor, String?.none).flatMap(CursorColor.init(stringValue:)) ?? s.cursorColor
        s.fullRefreshRate = value(.fullRefreshRate, s.fullRefreshRate)
        s.tintStrength = value(.tintStrength, s.tintStrength)
        s.tabLayout = value(.tabLayout, s.tabLayout)
        s.sidebarWidth = value(.sidebarWidth, s.sidebarWidth)
        s.tabListHidden = value(.tabListHidden, s.tabListHidden)
        s.newTabDirectory = value(.newTabDirectory, s.newTabDirectory)
        s.restoreSession = value(.restoreSession, s.restoreSession)
        s.confirmCloseRunning = value(.confirmCloseRunning, s.confirmCloseRunning)
        s.notifyCommands = value(.notifyCommands, s.notifyCommands)
        s.notifyAfterSeconds = value(.notifyAfterSeconds, s.notifyAfterSeconds)
        s.optionAsAlt = value(.optionAsAlt, s.optionAsAlt)
        s.vimNavigation = value(.vimNavigation, s.vimNavigation)
        s.secureKeyboardEntry = value(.secureKeyboardEntry, s.secureKeyboardEntry)
        s.clipboardRead = value(.clipboardRead, s.clipboardRead)
        s.clipboardWrite = value(.clipboardWrite, s.clipboardWrite)
        s.clipboardReadPrograms = value(.clipboardReadPrograms, s.clipboardReadPrograms)
        s.clipboardWritePrograms = value(.clipboardWritePrograms, s.clipboardWritePrograms)
        // Decode shortcuts one by one so a single bad entry does not drop the rest.
        if let raw = try? c.decodeIfPresent([String: String].self, forKey: .shortcuts) {
            s.shortcuts = raw.compactMapValues(Shortcut.init(string:))
        }
        // Older files saved every value, defaults included; carry them forward. A newer file
        // keeps its version so the store can reject it.
        if s.version < Self.currentVersion {
            if s.version < 2, s.tintStrength == 0.5 { s.tintStrength = 0 }
            s.version = Self.currentVersion
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
        try c.encode(cursorColor.stringValue, forKey: .cursorColor)
        try c.encode(fullRefreshRate, forKey: .fullRefreshRate)
        try c.encode(tintStrength, forKey: .tintStrength)
        try c.encode(tabLayout, forKey: .tabLayout)
        try c.encode(sidebarWidth, forKey: .sidebarWidth)
        try c.encode(tabListHidden, forKey: .tabListHidden)
        try c.encode(newTabDirectory, forKey: .newTabDirectory)
        try c.encode(restoreSession, forKey: .restoreSession)
        try c.encode(confirmCloseRunning, forKey: .confirmCloseRunning)
        try c.encode(notifyCommands, forKey: .notifyCommands)
        try c.encode(notifyAfterSeconds, forKey: .notifyAfterSeconds)
        try c.encode(optionAsAlt, forKey: .optionAsAlt)
        try c.encode(vimNavigation, forKey: .vimNavigation)
        try c.encode(secureKeyboardEntry, forKey: .secureKeyboardEntry)
        try c.encode(clipboardRead, forKey: .clipboardRead)
        try c.encode(clipboardWrite, forKey: .clipboardWrite)
        // Sorted, so the file does not change from one save to the next.
        try c.encode(clipboardReadPrograms.sorted(), forKey: .clipboardReadPrograms)
        try c.encode(clipboardWritePrograms.sorted(), forKey: .clipboardWritePrograms)
        try c.encode(shortcuts, forKey: .shortcuts)
    }
}
