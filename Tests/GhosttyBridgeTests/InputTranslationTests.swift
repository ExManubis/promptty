import XCTest
import AppKit
import GhosttyKit
@testable import GhosttyBridge

final class KeyRoutingTests: XCTestCase {
    func testKeysWithoutCommandGoToTheTerminal() {
        XCTAssertTrue(KeyRouting.terminalHandlesKeyEquivalent(flags: []))
        XCTAssertTrue(KeyRouting.terminalHandlesKeyEquivalent(flags: [.control]))
        XCTAssertTrue(KeyRouting.terminalHandlesKeyEquivalent(flags: [.control, .shift]))
        XCTAssertTrue(KeyRouting.terminalHandlesKeyEquivalent(flags: [.option]))
        XCTAssertTrue(KeyRouting.terminalHandlesKeyEquivalent(flags: [.control, .option, .shift]))
    }

    func testKeysWithCommandGoToTheMenuFirst() {
        XCTAssertFalse(KeyRouting.terminalHandlesKeyEquivalent(flags: [.command]))
        XCTAssertFalse(KeyRouting.terminalHandlesKeyEquivalent(flags: [.command, .control]))
        XCTAssertFalse(KeyRouting.terminalHandlesKeyEquivalent(flags: [.command, .shift, .option]))
    }
}

final class InputTranslationTests: XCTestCase {
    func testBasicModifiers() {
        XCTAssertEqual(InputTranslation.mods([]).rawValue, GHOSTTY_MODS_NONE.rawValue)
        XCTAssertEqual(InputTranslation.mods([.shift]).rawValue, GHOSTTY_MODS_SHIFT.rawValue)
        XCTAssertEqual(InputTranslation.mods([.command, .option]).rawValue,
                       GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_ALT.rawValue)
        XCTAssertEqual(InputTranslation.mods([.control, .capsLock]).rawValue,
                       GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_CAPS.rawValue)
    }

    func testRightSideModifiersUseDeviceBits() {
        let rightShift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | InputTranslation.deviceRightShift)
        XCTAssertEqual(InputTranslation.mods(rightShift).rawValue,
                       GHOSTTY_MODS_SHIFT.rawValue | GHOSTTY_MODS_SHIFT_RIGHT.rawValue)
        let rightCmd = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | InputTranslation.deviceRightCommand)
        XCTAssertEqual(InputTranslation.mods(rightCmd).rawValue,
                       GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SUPER_RIGHT.rawValue)
    }

    func testMouseButtons() {
        XCTAssertEqual(InputTranslation.mouseButton(0), GHOSTTY_MOUSE_LEFT)
        XCTAssertEqual(InputTranslation.mouseButton(1), GHOSTTY_MOUSE_RIGHT)
        XCTAssertEqual(InputTranslation.mouseButton(2), GHOSTTY_MOUSE_MIDDLE)
        XCTAssertEqual(InputTranslation.mouseButton(3), GHOSTTY_MOUSE_FOUR)
        XCTAssertEqual(InputTranslation.mouseButton(4), GHOSTTY_MOUSE_FIVE)
        XCTAssertEqual(InputTranslation.mouseButton(9), GHOSTTY_MOUSE_UNKNOWN)
    }

    func testScrollModsPackPrecisionInBitZeroAndMomentumAbove() {
        XCTAssertEqual(InputTranslation.scrollMods(precision: false, momentumPhase: []), 0)
        XCTAssertEqual(InputTranslation.scrollMods(precision: true, momentumPhase: []), 1)
        XCTAssertEqual(InputTranslation.scrollMods(precision: true, momentumPhase: .changed),
                       1 | (Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue) << 1))
        XCTAssertEqual(InputTranslation.scrollMods(precision: false, momentumPhase: .ended),
                       Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue) << 1)
    }

    func testModifierKeyCodes() {
        XCTAssertEqual(InputTranslation.modifierKey(forKeyCode: 56), .shift)
        XCTAssertEqual(InputTranslation.modifierKey(forKeyCode: 60), .shift)
        XCTAssertEqual(InputTranslation.modifierKey(forKeyCode: 55), .command)
        XCTAssertEqual(InputTranslation.modifierKey(forKeyCode: 58), .option)
        XCTAssertEqual(InputTranslation.modifierKey(forKeyCode: 59), .control)
        XCTAssertEqual(InputTranslation.modifierKey(forKeyCode: 57), .capsLock)
        XCTAssertNil(InputTranslation.modifierKey(forKeyCode: 0))
    }

    func testRightSideModifierPressRequiresItsDeviceBit() {
        // Right shift (60) released while left shift is still held: .shift remains, right bit cleared.
        XCTAssertFalse(InputTranslation.isSidePressed(keyCode: 60, flags: [.shift]))
        let rightShift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | InputTranslation.deviceRightShift)
        XCTAssertTrue(InputTranslation.isSidePressed(keyCode: 60, flags: rightShift))
        let rightCtrl = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | InputTranslation.deviceRightControl)
        XCTAssertTrue(InputTranslation.isSidePressed(keyCode: 62, flags: rightCtrl))
        XCTAssertFalse(InputTranslation.isSidePressed(keyCode: 61, flags: [.option]))
        XCTAssertFalse(InputTranslation.isSidePressed(keyCode: 54, flags: [.command]))
        // Left-side keys and caps lock are not side-checked (matches Ghostty's macOS app).
        XCTAssertTrue(InputTranslation.isSidePressed(keyCode: 56, flags: [.shift]))
        XCTAssertTrue(InputTranslation.isSidePressed(keyCode: 57, flags: [.capsLock]))
    }
}
