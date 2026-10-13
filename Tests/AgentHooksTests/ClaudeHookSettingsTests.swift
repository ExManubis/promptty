import AgentHooks
import XCTest

final class ClaudeHookSettingsTests: XCTestCase {
    private let helper = "/Applications/Prompt TTY.app/Contents/MacOS/promptty-hook"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeHookSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    private func commands(_ settings: [String: Any], _ event: String) -> [String] {
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    private let existing = #"""
    {
      "model": "opus",
      "permissions": {"allow": ["Bash(ls:*)"]},
      "env": {"FOO": "1"},
      "hooks": {
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/check-bash"}]}],
        "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "prettier --write"}]}]
      }
    }
    """#

    func testTheCommandQuotesTheHelperPath() {
        XCTAssertEqual(ClaudeHookSettings.command(helper: helper, event: .stop),
                       "'/Applications/Prompt TTY.app/Contents/MacOS/promptty-hook' Stop")
        XCTAssertEqual(ClaudeHookSettings.command(helper: "/a/it's/promptty-hook", event: .stop),
                       #"'/a/it'\''s/promptty-hook' Stop"#)
    }

    func testRecognisesItsOwnCommandsWhereverTheAppIs() {
        XCTAssertTrue(ClaudeHookSettings.isOurs(ClaudeHookSettings.command(helper: helper, event: .stop)))
        XCTAssertTrue(ClaudeHookSettings.isOurs("'/Users/me/Build/PrompTTY.app/Contents/MacOS/promptty-hook' PreToolUse"))
        XCTAssertTrue(ClaudeHookSettings.isOurs("/opt/PrompTTY.app/Contents/MacOS/promptty-hook Stop"))
        XCTAssertFalse(ClaudeHookSettings.isOurs("~/bin/check-bash"))
        XCTAssertFalse(ClaudeHookSettings.isOurs("/bin/promptty-hooks Stop"))
        XCTAssertFalse(ClaudeHookSettings.isOurs("echo promptty-hook"))
    }

    func testInstallIntoNothingAddsEveryEvent() throws {
        let settings = try object(ClaudeHookSettings.installing(helper: helper, into: nil))
        for event in ClaudeHookSettings.events {
            XCTAssertEqual(commands(settings, event.rawValue), [ClaudeHookSettings.command(helper: helper, event: event)], event.rawValue)
        }
        let group = try XCTUnwrap(((settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first)
        XCTAssertEqual(group["matcher"] as? String, "")
        XCTAssertEqual((group["hooks"] as? [[String: Any]])?.first?["type"] as? String, "command")
    }

    func testInstallKeepsEverythingElse() throws {
        let settings = try object(ClaudeHookSettings.installing(helper: helper, into: Data(existing.utf8)))
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual((settings["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls:*)"])
        XCTAssertEqual((settings["env"] as? [String: String]), ["FOO": "1"])
        XCTAssertEqual(commands(settings, "PreToolUse"), ["~/bin/check-bash", ClaudeHookSettings.command(helper: helper, event: .preToolUse)])
        XCTAssertEqual(commands(settings, "PostToolUse"), ["prettier --write", ClaudeHookSettings.command(helper: helper, event: .postToolUse)])
        // The user's own matcher stays on their group.
        let pre = try XCTUnwrap((settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(pre.first?["matcher"] as? String, "Bash")
    }

    func testInstallIsIdempotent() throws {
        let once = try ClaudeHookSettings.installing(helper: helper, into: Data(existing.utf8))
        let twice = try ClaudeHookSettings.installing(helper: helper, into: once)
        XCTAssertEqual(once, twice)
        XCTAssertTrue(try ClaudeHookSettings.isInstalled(helper: helper, in: once))
        XCTAssertFalse(try ClaudeHookSettings.isInstalled(helper: helper, in: Data(existing.utf8)))
    }

    func testInstallFromAnotherPlaceReplacesTheOldCommands() throws {
        let old = try ClaudeHookSettings.installing(helper: "/old/PrompTTY.app/Contents/MacOS/promptty-hook", into: Data(existing.utf8))
        let settings = try object(ClaudeHookSettings.installing(helper: helper, into: old))
        XCTAssertEqual(commands(settings, "Stop"), [ClaudeHookSettings.command(helper: helper, event: .stop)])
        XCTAssertEqual(commands(settings, "PreToolUse"), ["~/bin/check-bash", ClaudeHookSettings.command(helper: helper, event: .preToolUse)])
    }

    func testRemoveTakesOutOnlyItsOwnHooks() throws {
        let installed = try ClaudeHookSettings.installing(helper: helper, into: Data(existing.utf8))
        let removed = try ClaudeHookSettings.removing(from: installed)
        XCTAssertEqual(try object(removed) as NSDictionary, try object(Data(existing.utf8)) as NSDictionary)
        // Again: nothing more to take out.
        XCTAssertEqual(try ClaudeHookSettings.removing(from: removed), removed)
    }

    func testRemoveLeavesAGroupThatAlsoHoldsOtherHooks() throws {
        let mixed = #"""
        {"hooks": {"Stop": [{"matcher": "", "hooks": [
            {"type": "command", "command": "say done"},
            {"type": "command", "command": "'/x/PrompTTY.app/Contents/MacOS/promptty-hook' Stop"}
        ]}], "Empty": []}}
        """#
        let settings = try object(ClaudeHookSettings.removing(from: Data(mixed.utf8)))
        XCTAssertEqual(commands(settings, "Stop"), ["say done"])
        // What was empty before is not PrompTTY's to tidy away.
        XCTAssertNotNil((settings["hooks"] as? [String: Any])?["Empty"])
    }

    func testRemoveFromSettingsWithoutHooksIsNoChange() throws {
        let plain = Data(#"{"model":"opus"}"#.utf8)
        XCTAssertEqual(try object(ClaudeHookSettings.removing(from: plain)) as NSDictionary, ["model": "opus"] as NSDictionary)
        let installed = try object(ClaudeHookSettings.removing(from: ClaudeHookSettings.installing(helper: helper, into: plain)))
        XCTAssertNil(installed["hooks"])
    }

    func testSettingsThatAreNotAnObjectAreLeftAlone() {
        XCTAssertThrowsError(try ClaudeHookSettings.installing(helper: helper, into: Data("[1]".utf8)))
        XCTAssertThrowsError(try ClaudeHookSettings.installing(helper: helper, into: Data("{ broken".utf8)))
        XCTAssertThrowsError(try ClaudeHookSettings.installing(helper: helper, into: Data(#"{"hooks": []}"#.utf8)))
        XCTAssertThrowsError(try ClaudeHookSettings.installing(helper: helper, into: Data(#"{"hooks": {"Stop": {}}}"#.utf8)))
        XCTAssertThrowsError(try ClaudeHookSettings.removing(from: Data("{ broken".utf8)))
    }

    func testAnEmptyFileIsEmptySettings() throws {
        let settings = try object(ClaudeHookSettings.installing(helper: helper, into: Data("  \n".utf8)))
        XCTAssertEqual(commands(settings, "Stop").count, 1)
    }

    // MARK: Files

    func testInstallCreatesTheFileAndItsFolder() throws {
        let file = directory.appendingPathComponent(".claude/settings.json")
        XCTAssertEqual(try ClaudeHookSettings.install(helper: helper, in: file), .changed)
        XCTAssertTrue(try ClaudeHookSettings.isInstalled(helper: helper, in: Data(contentsOf: file)))
        // Nothing to back up: there was no file. A new file is the user's alone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".bak"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try ClaudeHookSettings.install(helper: helper, in: file), .unchanged)
    }

    func testInstallBacksUpTheFileFirstAndKeepsItsPermissions() throws {
        let file = directory.appendingPathComponent("settings.json")
        try Data(existing.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try ClaudeHookSettings.install(helper: helper, in: file), .changed)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("settings.json.bak"), encoding: .utf8), existing)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path + ".bak")[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try object(Data(contentsOf: file))["model"] as? String, "opus")
        // Nothing but the file and its backup: no temporary file left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["settings.json", "settings.json.bak"])
    }

    /// Install then remove: the first backup, the user's original, survives; the second goes beside it.
    func testALaterChangeKeepsTheFirstBackup() throws {
        let file = directory.appendingPathComponent("settings.json")
        try Data(existing.utf8).write(to: file)
        _ = try ClaudeHookSettings.install(helper: helper, in: file)
        let installed = try Data(contentsOf: file)
        XCTAssertEqual(try ClaudeHookSettings.remove(in: file), .changed)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("settings.json.bak"), encoding: .utf8), existing)
        let others = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("settings.json.bak-") }
        XCTAssertEqual(others.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(others[0])), installed)
    }

    func testBackupNames() throws {
        let file = directory.appendingPathComponent("settings.json")
        XCTAssertEqual(ClaudeHookSettings.backup(of: file).lastPathComponent, "settings.json.bak")
        try Data().write(to: directory.appendingPathComponent("settings.json.bak"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9, minute: 5, second: 7)))
        XCTAssertEqual(ClaudeHookSettings.backup(of: file, at: date).lastPathComponent, "settings.json.bak-20261013-090507")
        try Data().write(to: directory.appendingPathComponent("settings.json.bak-20261013-090507"))
        XCTAssertEqual(ClaudeHookSettings.backup(of: file, at: date).lastPathComponent, "settings.json.bak-20261013-090507-2")
    }

    func testInstallWritesThroughASymlink() throws {
        let real = directory.appendingPathComponent("dotfiles-settings.json")
        try Data(existing.utf8).write(to: real)
        let link = directory.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(try ClaudeHookSettings.install(helper: helper, in: link), .changed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertTrue(try ClaudeHookSettings.isInstalled(helper: helper, in: Data(contentsOf: real)))
    }

    func testABrokenFileIsNotTouched() throws {
        let file = directory.appendingPathComponent("settings.json")
        try Data("{ broken".utf8).write(to: file)
        XCTAssertThrowsError(try ClaudeHookSettings.install(helper: helper, in: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{ broken")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".bak"))
    }

    func testRemoveFromAFile() throws {
        let file = directory.appendingPathComponent("settings.json")
        try Data(existing.utf8).write(to: file)
        _ = try ClaudeHookSettings.install(helper: helper, in: file)
        XCTAssertEqual(try ClaudeHookSettings.remove(in: file), .changed)
        XCTAssertFalse(try ClaudeHookSettings.isInstalled(helper: helper, in: Data(contentsOf: file)))
        XCTAssertEqual(try object(Data(contentsOf: file)) as NSDictionary, try object(Data(existing.utf8)) as NSDictionary)
        XCTAssertEqual(try ClaudeHookSettings.remove(in: file), .unchanged)
        // No file: nothing to remove, and none made.
        let missing = directory.appendingPathComponent("none/settings.json")
        XCTAssertEqual(try ClaudeHookSettings.remove(in: missing), .unchanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testStatus() throws {
        let file = directory.appendingPathComponent("settings.json")
        XCTAssertEqual(ClaudeHookSettings.status(helper: helper, in: file), .notInstalled)
        _ = try ClaudeHookSettings.install(helper: "/old/PrompTTY.app/Contents/MacOS/promptty-hook", in: file)
        XCTAssertEqual(ClaudeHookSettings.status(helper: helper, in: file), .otherCopy)
        _ = try ClaudeHookSettings.install(helper: helper, in: file)
        XCTAssertEqual(ClaudeHookSettings.status(helper: helper, in: file), .installed)
        // One of this copy's hooks taken out by hand: partly installed, and installing completes it.
        var settings = try object(Data(contentsOf: file))
        var hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        hooks["Stop"] = nil
        settings["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: settings).write(to: file)
        XCTAssertEqual(ClaudeHookSettings.status(helper: helper, in: file), .partial)
        XCTAssertEqual(try ClaudeHookSettings.install(helper: helper, in: file), .changed)
        XCTAssertEqual(ClaudeHookSettings.status(helper: helper, in: file), .installed)
        try Data("{ broken".utf8).write(to: file)
        XCTAssertEqual(ClaudeHookSettings.status(helper: helper, in: file), .unreadable)
    }
}
