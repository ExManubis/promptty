import XCTest
@testable import Preferences

final class SettingsTests: XCTestCase {
    func testDefaultsMatchTheSpec() {
        let s = Settings()
        XCTAssertEqual(s.version, 2)
        XCTAssertEqual(s.fontFamily, "SF Mono")
        XCTAssertEqual(s.fontSize, 13)
        XCTAssertTrue(s.followSystemAppearance)
        XCTAssertEqual(s.lightTheme, "Flexoki Light")
        XCTAssertEqual(s.darkTheme, "Flexoki Dark")
        XCTAssertEqual(s.theme, "Flexoki Dark")
        XCTAssertEqual(s.cursorStyle, .block)
        XCTAssertTrue(s.cursorBlink)
        XCTAssertEqual(s.tintStrength, 0, "Dia-style neutral frame by default")
        XCTAssertEqual(s.tabLayout, .sidebar)
        XCTAssertEqual(s.sidebarWidth, 220)
        XCTAssertFalse(s.tabListHidden)
        XCTAssertEqual(s.newTabDirectory, .currentPane)
        XCTAssertTrue(s.restoreSession)
        XCTAssertTrue(s.confirmCloseRunning)
        XCTAssertEqual(s.optionAsAlt, .both)
        XCTAssertTrue(s.vimNavigation)
        XCTAssertFalse(s.fullRefreshRate, "ProMotion keeps lowering the refresh rate unless asked: battery")
        XCTAssertTrue(s.shortcuts.isEmpty)
    }

    func testFullRefreshRateIsSavedAndOffForOlderFiles() throws {
        var s = Settings()
        s.fullRefreshRate = true
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).fullRefreshRate)
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data(#"{"version":2}"#.utf8)).fullRefreshRate)
    }

    func testSecureKeyboardEntryIsSavedAndOffByDefault() throws {
        var s = Settings()
        XCTAssertFalse(s.secureKeyboardEntry)
        s.secureKeyboardEntry = true
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).secureKeyboardEntry)
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data(#"{"version":2}"#.utf8)).secureKeyboardEntry)
    }

    func testVimNavigationCanBeTurnedOffAndStaysOnForOlderFiles() throws {
        var s = Settings()
        s.vimNavigation = false
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertFalse(decoded.vimNavigation)
        let older = try JSONDecoder().decode(Settings.self, from: Data(#"{"version":2}"#.utf8))
        XCTAssertTrue(older.vimNavigation)
    }

    func testJSONRoundTrip() throws {
        var s = Settings()
        s.fontFamily = "Berkeley Mono"
        s.fontSize = 15
        s.cursorStyle = .bar
        s.optionAsAlt = .left
        s.shortcuts = ["splitRight": Shortcut(string: "opt+cmd+d")!]
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), s)
    }

    func testDecodingEmptyObjectGivesDefaults() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, Settings())
    }

    func testDecodingPartialObjectKeepsOtherDefaults() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"fontSize": 18, "cursorStyle": "underline"}"#.utf8))
        XCTAssertEqual(decoded.fontSize, 18)
        XCTAssertEqual(decoded.cursorStyle, .underline)
        XCTAssertEqual(decoded.fontFamily, "SF Mono")
    }

    func testDecodingUnknownEnumValueFallsBackToDefault() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"cursorStyle": "sparkle", "fontSize": 14}"#.utf8))
        XCTAssertEqual(decoded.cursorStyle, .block)
        XCTAssertEqual(decoded.fontSize, 14)
    }

    func testDecodingClampsOutOfRangeValues() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"fontSize": 500, "sidebarWidth": 10, "tintStrength": 3}"#.utf8))
        XCTAssertEqual(decoded.fontSize, 72)
        XCTAssertEqual(decoded.sidebarWidth, 180)
        XCTAssertEqual(decoded.tintStrength, 1)
    }

    func testNormalizedClampsLowValues() {
        var s = Settings()
        s.fontSize = 1
        s.sidebarWidth = 900
        s.tintStrength = -1
        let n = s.normalized()
        XCTAssertEqual(n.fontSize, 6)
        XCTAssertEqual(n.sidebarWidth, 320)
        XCTAssertEqual(n.tintStrength, 0)
    }

    /// Version 1 files saved every value, defaults included, so the old Frame color default (0.5)
    /// was frozen into them. It moves to the new neutral default; a value the user chose stays.
    func testVersion1FileWithOldFrameDefaultMovesToNeutral() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"version": 1, "tintStrength": 0.5}"#.utf8))
        XCTAssertEqual(decoded.tintStrength, 0)
        XCTAssertEqual(decoded.version, Settings.currentVersion)
    }

    func testVersion1FileWithChosenFrameColorKeepsIt() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"version": 1, "tintStrength": 0.8}"#.utf8))
        XCTAssertEqual(decoded.tintStrength, 0.8)
    }

    func testCurrentVersionFileKeepsHalfFrameColor() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"version": 2, "tintStrength": 0.5}"#.utf8))
        XCTAssertEqual(decoded.tintStrength, 0.5)
    }

    func testMigrationCarriesLayoutAndHiddenState() {
        let s = Settings.migrated(tabLayout: .strip, tabListHidden: true)
        XCTAssertEqual(s.tabLayout, .strip)
        XCTAssertTrue(s.tabListHidden)
        XCTAssertEqual(Settings.migrated(tabLayout: nil, tabListHidden: false), Settings())
    }

    @MainActor
    func testModelReportsOnlyRealChanges() {
        let model = SettingsModel(settings: Settings())
        var seen: [Settings] = []
        model.onChange = { seen.append($0) }
        model.settings.fontSize = 14
        model.settings.fontSize = 14
        XCTAssertEqual(seen.map(\.fontSize), [14])
    }

    @MainActor
    func testModelNormalizesAssignedSettings() {
        let model = SettingsModel(settings: Settings())
        model.settings.fontSize = 200
        XCTAssertEqual(model.settings.fontSize, 72)
    }
}

final class SettingsStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var url: URL { dir.appendingPathComponent("settings.json") }

    func testMissingFile() {
        XCTAssertEqual(SettingsStore(url: url).load(), .missing)
    }

    func testSaveThenLoad() throws {
        var s = Settings()
        s.fontSize = 16
        let store = SettingsStore(url: url)
        try store.save(s)
        XCTAssertEqual(store.load(), .loaded(s))
    }

    func testSaveCreatesDirectory() throws {
        let nested = SettingsStore(url: dir.appendingPathComponent("a/b/settings.json"))
        try nested.save(Settings())
        XCTAssertEqual(nested.load(), .loaded(Settings()))
    }

    func testGarbageIsMovedAsideAndReportedRecovered() throws {
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(SettingsStore(url: url).load(), .recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".bak"))
    }

    func testNewerVersionIsMovedAside() throws {
        try Data(#"{"version": 99}"#.utf8).write(to: url)
        XCTAssertEqual(SettingsStore(url: url).load(), .recovered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".bak"))
    }
}
