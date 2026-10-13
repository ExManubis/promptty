import XCTest
@testable import GhosttyBridge

final class LinkTargetTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("linktarget-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    @discardableResult
    private func make(_ name: String, _ body: String = "x", executable: Bool = false) throws -> String {
        let url = folder.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url.path
    }

    private func link(_ name: String, to target: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        return url.path
    }

    private func decide(_ text: String, _ kind: OpenURLKind = .unknown) -> LinkDecision {
        LinkTarget.decide(text, kind: kind, relativeTo: folder.path)
    }

    func testSchemeClasses() {
        XCTAssertEqual(decide("https://example.com/a?b=1"), .open(URL(string: "https://example.com/a?b=1")!))
        XCTAssertEqual(decide("http://example.com"), .open(URL(string: "http://example.com")!))
        XCTAssertEqual(decide("mailto:a@b.co"), .open(URL(string: "mailto:a@b.co")!))
        XCTAssertEqual(decide("ftp://example.com/f"), .open(URL(string: "ftp://example.com/f")!))
        XCTAssertEqual(decide("javascript:alert(1)"), .refuse)
        XCTAssertEqual(decide("data:text/html,hi"), .refuse)
        XCTAssertEqual(decide("ssh://host"), .confirm(URL(string: "ssh://host")!))
        XCTAssertEqual(decide("smb://host/share"), .confirm(URL(string: "smb://host/share")!))
        XCTAssertEqual(decide("x-man-page://ls"), .confirm(URL(string: "x-man-page://ls")!))
    }

    func testEmptyAndControlCharactersAreRefused() {
        XCTAssertEqual(decide(""), .refuse)
        XCTAssertEqual(decide("  \n"), .refuse)
        XCTAssertEqual(decide("https://a.co/\u{1B}[0m"), .refuse)
    }

    func testPathWithLineAndColumn() throws {
        let path = try make("foo.swift")
        XCTAssertEqual(decide("foo.swift:12"), .open(URL(fileURLWithPath: path)))
        XCTAssertEqual(decide("foo.swift:12:3"), .open(URL(fileURLWithPath: path)))
        XCTAssertEqual(decide("\(path):7"), .open(URL(fileURLWithPath: path)))
        XCTAssertEqual(decide("foo.swift:12", .text), .openAsText(URL(fileURLWithPath: path)))
    }

    func testNotURLsAndNotFilesAreRefused() throws {
        XCTAssertEqual(decide("README.md:3"), .refuse)
        XCTAssertEqual(decide("localhost:8080"), .refuse)
        XCTAssertEqual(decide("nope.txt"), .refuse)
        try make("a.txt")
        XCTAssertEqual(LinkTarget.decide("a.txt"), .refuse, "a relative path needs a directory")
    }

    func testFileKinds() throws {
        let note = try make("notes.txt")
        XCTAssertEqual(decide(note), .open(URL(fileURLWithPath: note)))
        XCTAssertEqual(decide("file://\(note)"), .open(URL(fileURLWithPath: note)))
        XCTAssertEqual(decide(try make("blob.xyz123")), .reveal(URL(fileURLWithPath: folder.appendingPathComponent("blob.xyz123").path)))
        XCTAssertEqual(decide(folder.path), .open(folder))
    }

    func testProgramsAreRefused() throws {
        let script = try make("run.sh", "#!/bin/sh\n", executable: true)
        XCTAssertEqual(decide(script), .refuse)
        XCTAssertEqual(decide("file://\(script)"), .refuse)
        XCTAssertEqual(decide(try make("tool.command", "#!/bin/sh\n")), .refuse)
        XCTAssertEqual(decide(try make("x.terminal", "<plist/>")), .refuse)
        XCTAssertEqual(decide(try make("x.webloc", "<plist/>")), .refuse)
        XCTAssertEqual(decide(try make("x.dmg")), .refuse)
        XCTAssertEqual(decide(try make("x.pkg")), .refuse)
        let app = folder.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(decide(app.path), .refuse)
    }

    func testSymlinksAreJudgedByTheirTarget() throws {
        let app = folder.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(decide(try link("innocent", to: app.path)), .refuse)
        let script = try make("run.sh", "#!/bin/sh\n", executable: true)
        XCTAssertEqual(decide(try link("readme.txt", to: script)), .refuse)
    }

    func testScriptsMayOnlyBeReadInATextEditor() throws {
        let script = try make("run.sh", "#!/bin/sh\n", executable: true)
        XCTAssertEqual(decide(script, .text), .openAsText(URL(fileURLWithPath: script)))
        let app = folder.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(decide(app.path, .text), .refuse)
    }
}
