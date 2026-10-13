import GhosttyBridge
import XCTest

final class PromptAnswerKeyTests: XCTestCase {
    private func answers(_ keyCode: UInt16, _ characters: String?, command: Bool = false, control: Bool = false) -> Bool {
        PromptAnswerKey.answers(keyCode: keyCode, characters: characters, command: command, control: control)
    }

    func testAnswers() {
        XCTAssertTrue(answers(36, "\r"))      // Return
        XCTAssertTrue(answers(76, "\u{3}"))   // keypad Enter
        XCTAssertTrue(answers(53, "\u{1b}"))  // Esc
        XCTAssertTrue(answers(16, "y"))
        XCTAssertTrue(answers(16, "Y"))
        XCTAssertTrue(answers(45, "n"))
        XCTAssertTrue(answers(18, "1"))
        XCTAssertTrue(answers(8, "c", control: true))
    }

    func testMovingAndOtherKeysDoNot() {
        XCTAssertFalse(answers(126, "\u{F700}"))  // up arrow
        XCTAssertFalse(answers(125, "\u{F701}"))  // down arrow
        XCTAssertFalse(answers(48, "\t"))
        XCTAssertFalse(answers(0, "a"))
        XCTAssertFalse(answers(16, "y", command: true))
        XCTAssertFalse(answers(36, "\r", command: true))
        XCTAssertFalse(answers(45, "n", control: true))
        XCTAssertFalse(answers(0, nil))
    }
}
