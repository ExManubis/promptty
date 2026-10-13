import XCTest
@testable import Preferences

final class ThemeCatalogTests: XCTestCase {
    static let flexokiDark = """
    palette = 0=#100f0f
    palette = 1=#d14d41
    palette = 2=#879a39
    palette = 15=#cecdc3
    background = #100f0f
    foreground = #cecdc3
    cursor-color = #cecdc3
    """

    func testParsesBackgroundForegroundAndPalette() {
        let swatch = ThemeCatalog.parse(Self.flexokiDark)
        XCTAssertEqual(swatch?.background, RGB(hex: "#100f0f"))
        XCTAssertEqual(swatch?.foreground, RGB(hex: "#cecdc3"))
        XCTAssertEqual(swatch?.palette[1], RGB(hex: "#d14d41"))
        XCTAssertEqual(swatch?.palette[15], RGB(hex: "#cecdc3"))
        XCTAssertNil(swatch?.palette[5])
    }

    func testParseNeedsBackgroundAndForeground() {
        XCTAssertNil(ThemeCatalog.parse("palette = 1=#ffffff"))
    }

    func testRGBHex() {
        XCTAssertEqual(RGB(hex: "#FFFCF0"), RGB(r: 255, g: 252, b: 240))
        XCTAssertEqual(RGB(hex: "fffcf0"), RGB(r: 255, g: 252, b: 240))
        XCTAssertNil(RGB(hex: "#fff"))
        XCTAssertNil(RGB(hex: "#gggggg"))
        XCTAssertEqual(RGB(r: 16, g: 15, b: 15).luminance, 0.0587, accuracy: 0.001)
    }

    func testCatalogListsThemeFilesSorted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["zenburn", "Flexoki Dark", "ayu", ".hidden"] {
            try Self.flexokiDark.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let catalog = ThemeCatalog(directory: dir)
        XCTAssertEqual(catalog.names, ["ayu", "Flexoki Dark", "zenburn"])
        XCTAssertTrue(catalog.contains("Flexoki Dark"))
        XCTAssertFalse(catalog.contains(".hidden"))
        XCTAssertEqual(catalog.swatch(for: "ayu")?.background, RGB(hex: "#100f0f"))
        XCTAssertNil(catalog.swatch(for: "missing"))
    }
}

final class TerminalConfigWriterTests: XCTestCase {
    private let themes: Set<String> = ["Flexoki Light", "Flexoki Dark", "Dracula"]

    private func lines(_ s: Settings) -> [String] {
        TerminalConfigWriter.render(s, knownThemes: themes).split(separator: "\n").map(String.init)
    }

    func testFirstLineClearsAllKeybinds() {
        XCTAssertEqual(lines(Settings()).first, "keybind = clear")
    }

    func testDefaultOutput() {
        let l = lines(Settings())
        XCTAssertTrue(l.contains("font-family = SF Mono"))
        XCTAssertTrue(l.contains("font-size = 13"))
        XCTAssertTrue(l.contains("theme = light:Flexoki Light,dark:Flexoki Dark"))
        XCTAssertTrue(l.contains("cursor-style = block"))
        XCTAssertTrue(l.contains("cursor-style-blink = true"))
        XCTAssertTrue(l.contains("macos-option-as-alt = true"))
        XCTAssertTrue(l.contains("confirm-close-surface = true"))
    }

    func testNoOtherKeybindLines() {
        XCTAssertEqual(lines(Settings()).filter { $0.hasPrefix("keybind") }, ["keybind = clear"])
    }

    func testSingleThemeWhenNotFollowingSystem() {
        var s = Settings()
        s.followSystemAppearance = false
        s.theme = "Dracula"
        XCTAssertTrue(lines(s).contains("theme = Dracula"))
    }

    func testUnknownThemesFallBackToFlexoki() {
        var s = Settings()
        s.lightTheme = "Gone Light"
        s.darkTheme = "Gone Dark"
        XCTAssertTrue(lines(s).contains("theme = light:Flexoki Light,dark:Flexoki Dark"))
        s.followSystemAppearance = false
        s.theme = "Gone"
        XCTAssertTrue(lines(s).contains("theme = Flexoki Dark"))
    }

    func testThemesAreNotValidatedWithoutACatalog() {
        var s = Settings()
        s.darkTheme = "Anything"
        let text = TerminalConfigWriter.render(s, knownThemes: nil)
        XCTAssertTrue(text.contains("theme = light:Flexoki Light,dark:Anything"))
    }

    func testOptionAsAltMapping() {
        var s = Settings()
        let expected: [OptionAsAlt: String] = [.both: "true", .left: "left", .right: "right", .off: "false"]
        for (value, rendered) in expected {
            s.optionAsAlt = value
            XCTAssertTrue(lines(s).contains("macos-option-as-alt = \(rendered)"), "\(value)")
        }
    }

    func testClipboardAccessLines() {
        var s = Settings()
        XCTAssertTrue(lines(s).contains("clipboard-read = ask"))
        XCTAssertTrue(lines(s).contains("clipboard-write = ask"))
        s.clipboardRead = .deny
        s.clipboardWrite = .allow
        XCTAssertTrue(lines(s).contains("clipboard-read = deny"))
        XCTAssertTrue(lines(s).contains("clipboard-write = allow"))
    }

    func testFractionalFontSizeAndCursor() {
        var s = Settings()
        s.fontSize = 13.5
        s.cursorStyle = .underline
        s.cursorBlink = false
        s.confirmCloseRunning = false
        let l = lines(s)
        XCTAssertTrue(l.contains("font-size = 13.5"))
        XCTAssertTrue(l.contains("cursor-style = underline"))
        XCTAssertTrue(l.contains("cursor-style-blink = false"))
        XCTAssertTrue(l.contains("confirm-close-surface = false"))
    }

    func testValuesCannotInjectExtraLines() {
        var s = Settings()
        s.fontFamily = "Evil\nkeybind = ctrl+c=quit"
        let l = lines(s)
        XCTAssertEqual(l.filter { $0.hasPrefix("keybind") }, ["keybind = clear"])
        XCTAssertTrue(l.contains("font-family = Evilkeybind = ctrl+c=quit"))
    }

    func testEmptyFontFamilyFallsBackToSFMono() {
        var s = Settings()
        s.fontFamily = "  "
        XCTAssertTrue(lines(s).contains("font-family = SF Mono"))
    }
}
