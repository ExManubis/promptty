import XCTest
@testable import CommandEditing

final class ZshIntegrationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRecognizesZshByName() {
        XCTAssertTrue(ZshIntegration.isZsh(shellPath: "/bin/zsh"))
        XCTAssertTrue(ZshIntegration.isZsh(shellPath: "/opt/homebrew/bin/zsh"))
        XCTAssertFalse(ZshIntegration.isZsh(shellPath: "/bin/bash"))
        XCTAssertFalse(ZshIntegration.isZsh(shellPath: "/usr/local/bin/fish"))
        XCTAssertFalse(ZshIntegration.isZsh(shellPath: ""))
    }

    func testInstallWritesTheZshenvAndIsIdempotent() throws {
        let installed = try ZshIntegration.install(in: dir)
        let file = installed.appendingPathComponent(".zshenv")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), ZshIntegration.zshenv)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        _ = try ZshIntegration.install(in: dir)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "an unchanged script is not rewritten")
    }

    func testInstallReplacesAStaleScript() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "old".write(to: dir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        _ = try ZshIntegration.install(in: dir)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(".zshenv"), encoding: .utf8), ZshIntegration.zshenv)
    }

    func testEnvironmentPointsZshAtTheIntegration() {
        let env = ZshIntegration.environment(integrationDirectory: URL(fileURLWithPath: "/x/zsh"), stateFile: URL(fileURLWithPath: "/x/state/1"), userZDOTDIR: nil)
        XCTAssertEqual(env, ["ZDOTDIR": "/x/zsh", "PROMPTTY_STATE": "/x/state/1"])
    }

    func testEnvironmentCarriesTheUsersOwnZDOTDIR() {
        let env = ZshIntegration.environment(integrationDirectory: URL(fileURLWithPath: "/x/zsh"), stateFile: URL(fileURLWithPath: "/x/s"), userZDOTDIR: "/Users/me/.config/zsh")
        XCTAssertEqual(env["PROMPTTY_ZDOTDIR"], "/Users/me/.config/zsh")
    }

    func testReadyReportsAreToldApartFromDirectoryReports() {
        XCTAssertEqual(ZshIntegration.readyDirectory(fromReportedPath: "/.promptty-ready/Users/me/x"), "/Users/me/x")
        XCTAssertEqual(ZshIntegration.readyDirectory(fromReportedPath: "/.promptty-ready/"), "/")
        XCTAssertEqual(ZshIntegration.readyDirectory(fromReportedPath: "/.promptty-ready"), "/")
        XCTAssertNil(ZshIntegration.readyDirectory(fromReportedPath: "/Users/me/x"))
        XCTAssertNil(ZshIntegration.readyDirectory(fromReportedPath: "/.promptty-readyish/x"))
    }

    func testScriptSignalsReadinessFromZleLineInit() {
        let s = ZshIntegration.zshenv
        XCTAssertTrue(s.contains("add-zle-hook-widget line-init _promptty_line_init"))
        XCTAssertTrue(s.contains("/.promptty-ready${PWD}"))
        XCTAssertTrue(s.contains("zle' reset-prompt"))
    }

    /// Clearing the prompt line erases the terminal's mark on it; the line is marked again after,
    /// so each command starts a block (see the engine's blocks.zig).
    func testLineInitMarksThePromptAfterClearingIt() throws {
        let s = ZshIntegration.zshenv
        let body = try XCTUnwrap(s.range(of: "_promptty_line_init() {").map { s[$0.upperBound...] })
        let end = try XCTUnwrap(body.range(of: "\n    }\n"))
        let lineInit = String(body[..<end.lowerBound])
        let reset = try XCTUnwrap(lineInit.range(of: "reset-prompt"))
        let mark = try XCTUnwrap(lineInit.range(of: "\\e]133;P;k=i\\a\\e]133;B\\a"))
        XCTAssertLessThan(reset.lowerBound, mark.lowerBound)
    }

    func testScriptHasTheHooksTheAppRelies() {
        let s = ZshIntegration.zshenv
        for needle in ["_promptty_init", "_promptty_precmd", "_promptty_preexec", "'unsetopt' hist_verify",
                       "kitty-shell-cwd://", "\\e[?25l", "\\e[?25h", "PROMPTTY_STATE", "RPROMPT=''"] {
            XCTAssertTrue(s.contains(needle), "missing \(needle)")
        }
    }

    func testScriptIsValidZsh() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/zsh"))
        let installed = try ZshIntegration.install(in: dir)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-n", installed.appendingPathComponent(".zshenv").path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0, message)
    }

    /// Runs the integration in a real interactive zsh with an empty home and checks the state file
    /// and the hidden prompt: the closest thing to a pane without a window.
    func testScriptRunsInAnInteractiveShell() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/zsh"))
        let home = dir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "alias ll='ls -l'\nmyfn() { :; }\nHISTFILE=$HOME/.hist\nPROMPT='starship> '\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let installed = try ZshIntegration.install(in: dir.appendingPathComponent("zsh"))
        let state = dir.appendingPathComponent("state")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-i", "-c", "for f in $precmd_functions; do $f; done; print -r -- \"[$PROMPT][$RPROMPT]\""]
        var env = ZshIntegration.environment(integrationDirectory: installed, stateFile: state, userZDOTDIR: nil)
        env["HOME"] = home.path
        env["PATH"] = "/usr/bin:/bin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // Hidden: nothing to show but the marks the terminal finds commands by (zero-width, so
        // every redraw of the prompt, such as clearing the screen, prints them again).
        XCTAssertTrue(output.hasSuffix("[%{\u{1b}]133;P;k=i\u{07}\u{1b}]133;B\u{07}%}][]\n"), output.debugDescription)
        let parsed = ShellStateFile.parse(try String(contentsOf: state, encoding: .utf8))
        XCTAssertEqual(parsed.historyFile, home.path + "/.hist")
        XCTAssertEqual(parsed.path, ["/usr/bin", "/bin"])
        XCTAssertTrue(parsed.aliases.contains("ll"))
        XCTAssertTrue(parsed.functions.contains("myfn"))
        XCTAssertTrue(parsed.builtins.contains("cd"))
        XCTAssertTrue(parsed.reserved.contains("if"))
        XCTAssertTrue(parsed.exports.contains("HOME"))
    }
}

final class ShellStateFileTests: XCTestCase {
    func testParsesEveryKind() {
        let s = ShellStateFile.parse("""
        histfile /Users/me/.zsh_history
        path /opt/homebrew/bin:/usr/bin:/bin
        alias ll
        alias g
        function nvm
        builtin cd
        reserved if
        export EDITOR
        """)
        XCTAssertEqual(s.historyFile, "/Users/me/.zsh_history")
        XCTAssertEqual(s.path, ["/opt/homebrew/bin", "/usr/bin", "/bin"])
        XCTAssertEqual(s.aliases, ["ll", "g"])
        XCTAssertEqual(s.functions, ["nvm"])
        XCTAssertEqual(s.builtins, ["cd"])
        XCTAssertEqual(s.reserved, ["if"])
        XCTAssertEqual(s.exports, ["EDITOR"])
        XCTAssertEqual(s.commandNames, ["ll", "g", "nvm", "cd", "if"])
    }

    func testKeepsSpacesInValuesAndSkipsJunk() {
        let s = ShellStateFile.parse("histfile /Users/me/My History\nnonsense\n\npath /a b:/c\nalias\n")
        XCTAssertEqual(s.historyFile, "/Users/me/My History")
        XCTAssertEqual(s.path, ["/a b", "/c"])
        XCTAssertTrue(s.aliases.isEmpty)
    }

    func testEmptyPathEntriesAreDropped() {
        XCTAssertEqual(ShellStateFile.parse("path /a::/b:").path, ["/a", "/b"])
    }
}
