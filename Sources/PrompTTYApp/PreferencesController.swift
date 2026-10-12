import Foundation
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
    }

    var settings: Settings { model.settings }
    var shortcuts: ShortcutMap { model.shortcuts }

    /// Writes `terminal.conf` if its text changed. Returns whether it changed.
    @discardableResult
    func writeTerminalConfig() throws -> Bool {
        let text = TerminalConfigWriter.render(model.settings, knownThemes: themes.names.isEmpty ? nil : Set(themes.names))
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
