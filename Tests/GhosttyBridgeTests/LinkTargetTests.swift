import XCTest
@testable import GhosttyBridge

final class LinkTargetTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("linktarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func make(_ name: String, executable: Bool = false) throws -> String {
        let url = folder.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url.path
    }

    func testSchemesPassThrough() {
        XCTAssertEqual(LinkTarget.resolve("https://example.com/a?b=1"), URL(string: "https://example.com/a?b=1"))
        XCTAssertEqual(LinkTarget.resolve("mailto:a@b.co"), URL(string: "mailto:a@b.co"))
    }

    func testEmptyAndControlCharactersAreIgnored() {
        XCTAssertNil(LinkTarget.resolve(""))
        XCTAssertNil(LinkTarget.resolve("  \n"))
        XCTAssertNil(LinkTarget.resolve("https://a.co/\u{1B}[0m"))
    }

    func testExistingFileOpens() throws {
        let path = try make("notes.txt")
        XCTAssertEqual(LinkTarget.resolve(path)?.path, path)
        XCTAssertEqual(LinkTarget.resolve("notes.txt", relativeTo: folder.path)?.path, path)
        XCTAssertEqual(LinkTarget.resolve("file://\(path)")?.path, path)
    }

    func testMissingAndRelativeWithoutBaseAreIgnored() throws {
        XCTAssertNil(LinkTarget.resolve(folder.appendingPathComponent("nope").path))
        _ = try make("a.txt")
        XCTAssertNil(LinkTarget.resolve("a.txt"))
    }

    func testProgramsAreNotOpened() throws {
        XCTAssertNil(LinkTarget.resolve(try make("run.sh", executable: true)))
        let app = folder.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertNil(LinkTarget.resolve(app.path))
        XCTAssertEqual(LinkTarget.resolve(folder.path)?.path, folder.path)
    }
}
