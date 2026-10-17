import AppKit
import GhosttyBridge
import Preferences
import WorkspaceModel

/// Owns the live settings: loads `settings.json` (migrating on first launch), saves changes,
/// regenerates `terminal.conf`, and tells the app what kind of change happened.
@MainActor
final class PreferencesController {
    let model: SettingsModel
    let themes: ThemeCatalog
    let terminalConfigURL: URL
    /// True when `settings.json` was unusable at launch and defaults were used.
    let recoveredFromBadFile: Bool

    /// libghostty must re-read `terminal.conf`.
    var onTerminalConfigChanged: (() -> Void)?
    /// Menu key equivalents must be rebuilt.
    var onShortcutsChanged: ((ShortcutMap) -> Void)?
    /// Layout, sidebar, tint and other app-only settings changed.
    var onAppSettingsChanged: ((Settings) -> Void)?

    private let store: SettingsStore
    private var saver: DebouncedSaver!
    private var lastConfigText: String?
    private var accentObserver: NSObjectProtocol?

    static let legacyTabListHiddenKey = "tabListHidden"

    init(supportDirectory: URL, themesDirectory: URL, legacyTabLayout: TabLayout?) {
        store = SettingsStore(url: supportDirectory.appendingPathComponent("settings.json"))
        terminalConfigURL = supportDirectory.appendingPathComponent("terminal.conf")
        themes = ThemeCatalog(directory: themesDirectory)

        let initial: Settings
        switch store.load() {
        case .loaded(let s):
            initial = s
            recoveredFromBadFile = false
        case .recovered:
            initial = Settings()
            recoveredFromBadFile = true
        case .missing:
            let defaults = UserDefaults.standard
            initial = Settings.migrated(
                tabLayout: legacyTabLayout.map { $0 == .strip ? .strip : .sidebar },
                tabListHidden: defaults.bool(forKey: Self.legacyTabListHiddenKey)
            )
            defaults.removeObject(forKey: Self.legacyTabListHiddenKey)
            recoveredFromBadFile = false
        }
        model = SettingsModel(settings: initial)
        previous = model.settings
        saver = DebouncedSaver(delay: .milliseconds(300)) { [weak self] in self?.save() }
        model.onChange = { [weak self] new in self?.settingsDidChange(from: new) }
        save()
        // An accent-colored cursor follows the accent color chosen in System Settings.
        accentObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.settings.cursorColor == .accent, (try? self.writeTerminalConfig()) == true else { return }
                self.onTerminalConfigChanged?()
            }
        }
    }

    /// The system accent color as 0xRRGGBB.
    static var accentColor: UInt32? {
        guard let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }

    /// The cursor's color for the input bar's caret; nil for the theme's (the text color).
    var cursorColor: NSColor? {
        model.settings.resolvedCursorColor(accent: Self.accentColor).map {
            NSColor(srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255, green: CGFloat(($0 >> 8) & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1)
        }
    }

    var settings: Settings { model.settings }
    var shortcuts: ShortcutMap { model.shortcuts }

    /// Writes `terminal.conf` if its text changed. Returns whether it changed.
    @discardableResult
    func writeTerminalConfig() throws -> Bool {
        let text = TerminalConfigWriter.render(model.settings, knownThemes: themes.names.isEmpty ? nil : themes.nameSet,
                                               accentColor: Self.accentColor)
        guard text != lastConfigText else { return false }
        try FileManager.default.createDirectory(at: terminalConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: terminalConfigURL, atomically: true, encoding: .utf8)
        lastConfigText = text
        return true
    }

    func update(_ change: (inout Settings) -> Void) {
        var s = model.settings
        change(&s)
        model.settings = s
    }

    func resetToDefaults() { model.settings = Settings() }

    func flush() { saver.flush() }

    private var previous: Settings?

    private func settingsDidChange(from new: Settings) {
        let old = previous ?? new
        previous = new
        saver.schedule()
        if (try? writeTerminalConfig()) == true { onTerminalConfigChanged?() }
        if old.shortcuts != new.shortcuts { onShortcutsChanged?(ShortcutMap(overrides: new.shortcuts)) }
        onAppSettingsChanged?(new)
    }

    private func save() {
        do {
            try store.save(model.settings)
        } catch {
            NSLog("PrompTTY: could not save settings: \(error)")
        }
    }
}

extension TabLayout {
    init(_ setting: TabLayoutSetting) { self = setting == .strip ? .strip : .sidebar }
}

extension Settings {
    /// The programs allowed to do `kind` without asking.
    func clipboardPrograms(_ kind: ClipboardRequestKind) -> Set<String> {
        kind == .read ? clipboardReadPrograms : clipboardWritePrograms
    }

    mutating func allowClipboard(_ kind: ClipboardRequestKind, for program: String) {
        if kind == .read { clipboardReadPrograms.insert(program) } else { clipboardWritePrograms.insert(program) }
    }
}
