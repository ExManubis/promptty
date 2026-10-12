import CommandEditing
import XCTest

final class PinnedCommandTests: XCTestCase {
    func testNothingRunningPinsNoCommand() {
        XCTAssertNil(PinnedCommand.capture(running: false, lastCommand: "ls", arguments: nil))
    }

    func testTheCommandAsTypedWinsOverTheProcessArguments() {
        XCTAssertEqual(
            PinnedCommand.capture(running: true, lastCommand: "npm run dev",
                                  arguments: ["node", "/opt/npm/bin/npm-cli.js", "run", "dev"]),
            "npm run dev"
        )
    }

    func testWithoutATypedCommandTheArgumentsAreQuoted() {
        XCTAssertEqual(
            PinnedCommand.capture(running: true, lastCommand: nil, arguments: ["vim", "my notes.md", "$HOME"]),
            "vim my\\ notes.md \\$HOME"
        )
    }

    func testAnEmptyArgumentIsKept() {
        XCTAssertEqual(PinnedCommand.capture(running: true, lastCommand: nil, arguments: ["grep", "", "file"]), "grep '' file")
    }

    func testUnreadableArgumentsPinNoCommand() {
        XCTAssertNil(PinnedCommand.capture(running: true, lastCommand: nil, arguments: nil))
        XCTAssertNil(PinnedCommand.capture(running: true, lastCommand: "  ", arguments: []))
    }
}
