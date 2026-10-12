import XCTest
import Preferences
@testable import GhosttyBridge

/// The generated terminal.conf must be a config libghostty accepts without complaint.
final class ConfigFileTests: XCTestCase {
    private func write(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).conf")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testGeneratedDefaultConfigHasNoDiagnostics() throws {
        let url = try write(TerminalConfigWriter.render(Settings(), knownThemes: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try GhosttyConfigFile.diagnostics(forFileAt: url), [])
    }

    func testEveryOptionValueIsAccepted() throws {
        for alt in OptionAsAlt.allCases {
            for cursor in CursorStyle.allCases {
                var s = Settings()
                s.optionAsAlt = alt
                s.cursorStyle = cursor
                s.followSystemAppearance = alt == .off
                s.fontSize = 13.5
                let url = try write(TerminalConfigWriter.render(s, knownThemes: nil))
                defer { try? FileManager.default.removeItem(at: url) }
                XCTAssertEqual(try GhosttyConfigFile.diagnostics(forFileAt: url), [], "\(alt) \(cursor)")
            }
        }
    }

    func testBadValueIsReported() throws {
        let url = try write("font-size = banana\n")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try GhosttyConfigFile.diagnostics(forFileAt: url).isEmpty)
    }

    func testBundledThemesIncludeFlexoki() throws {
        let catalog = ThemeCatalog(directory: try GhosttyLibrary.themesDirectory())
        XCTAssertTrue(catalog.contains("Flexoki Light"))
        XCTAssertTrue(catalog.contains("Flexoki Dark"))
        XCTAssertEqual(catalog.swatch(for: "Flexoki Light")?.background, RGB(hex: "#fffcf0"))
        XCTAssertGreaterThan(catalog.names.count, 100)
    }
}
