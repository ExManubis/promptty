import CommandEditing
import XCTest

final class FolderLabelTests: XCTestCase {
    private let home = "/Users/me"

    private func label(_ path: String) -> String { FolderLabel.short(path, home: home) }

    func testShortPathsStayWhole() {
        XCTAssertEqual(label("/Users/me"), "~")
        XCTAssertEqual(label("/Users/me/Developer"), "~/Developer")
        XCTAssertEqual(label("/Users/me/Developer/promptty-2"), "~/Developer/promptty-2")
        XCTAssertEqual(label("/"), "/")
        XCTAssertEqual(label("/usr/local/bin"), "/usr/local/bin")
    }

    /// Deeper than that: the last two folders, after an ellipsis.
    func testDeepPathsKeepTheirLastTwoFolders() {
        XCTAssertEqual(label("/Users/me/Developer/clients/acme/web"), "…/acme/web")
        XCTAssertEqual(label("/Users/me/a/b/c"), "…/b/c")
        XCTAssertEqual(label("/opt/homebrew/lib/node_modules"), "…/lib/node_modules")
        XCTAssertEqual(label("/Users/other/src/app"), "…/src/app")
    }

    func testATrailingSlashChangesNothing() {
        XCTAssertEqual(label("/Users/me/Developer/clients/acme/web/"), "…/acme/web")
    }
}
