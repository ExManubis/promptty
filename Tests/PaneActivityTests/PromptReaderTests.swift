import XCTest
@testable import PaneActivity

final class PromptReaderTests: XCTestCase {
    func testReadsClaudeCodesPermissionBox() {
        let screen = """
        ⏺ Read(Sources/RemoteControl/ControlSocket.swift)
          ⎿  Read 214 lines

        ╭──────────────────────────────────────────────────╮
        │ Bash command                                     │
        │                                                  │
        │   swift test --filter RemoteProtocol             │
        │   Run the protocol's tests                       │
        │                                                  │
        │ Do you want to proceed?                          │
        │ ❯ 1. Yes                                         │
        │   2. Yes, and don't ask again for swift test     │
        │   3. No, and tell Claude what to do differently  │
        ╰──────────────────────────────────────────────────╯
        """
        let prompt = PromptReader.read(screen)
        XCTAssertEqual(prompt?.question, "Do you want to proceed?")
        XCTAssertEqual(prompt?.choices, [
            .init(number: 1, label: "Yes", selected: true),
            .init(number: 2, label: "Yes, and don't ask again for swift test"),
            .init(number: 3, label: "No, and tell Claude what to do differently"),
        ])
        XCTAssertEqual(prompt?.title, "Bash command")
        XCTAssertEqual(prompt?.detail, ["swift test --filter RemoteProtocol", "Run the protocol's tests"])
    }

    func testABoxWithoutABlankLineKeepsItsTitle() {
        let screen = """
        ╭────────────────╮
        │ Bash command   │
        │   make lint    │
        │ Proceed?       │
        │ ❯ 1. Yes       │
        │   2. No        │
        ╰────────────────╯
        """
        let prompt = PromptReader.read(screen)
        XCTAssertEqual(prompt?.title, "Bash command")
        XCTAssertEqual(prompt?.detail, ["make lint"])
        XCTAssertEqual(prompt?.choices.map(\.number), [1, 2])
    }

    func testNoPromptOnAnOrdinaryScreen() {
        XCTAssertNil(PromptReader.read("$ ls\n1. notes.txt\nREADME.md\n"))
        XCTAssertNil(PromptReader.read(""))
    }
}
