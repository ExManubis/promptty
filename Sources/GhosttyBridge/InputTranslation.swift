import AppKit
import GhosttyKit

/// Pure NSEvent → libghostty input conversions. No surface access, fully testable.
enum InputTranslation {
    // Device-dependent modifier bits from IOKit's IOLLEvent.h (NX_DEVICER*KEYMASK).
    // AppKit preserves them in ModifierFlags.rawValue; there is no named constant in AppKit.
    static let deviceRightShift: UInt = 0x0000_0004
    static let deviceRightControl: UInt = 0x0000_2000
    static let deviceRightOption: UInt = 0x0000_0040
    static let deviceRightCommand: UInt = 0x0000_0010

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        let device = flags.rawValue
        if device & deviceRightShift != 0 { raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if device & deviceRightControl != 0 { raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if device & deviceRightOption != 0 { raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if device & deviceRightCommand != 0 { raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    static func mouseButton(_ buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    /// Mirrors Ghostty's packed ScrollMods: bit 0 = precision, bits 1..3 = momentum.
    static func scrollMods(precision: Bool, momentumPhase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var packed: Int32 = precision ? 1 : 0
        let momentum: ghostty_input_mouse_momentum_e
        switch momentumPhase {
        case .began: momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        default: momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        packed |= Int32(momentum.rawValue) << 1
        return packed
    }

    /// Which modifier a `flagsChanged` event's keyCode refers to.
    static func modifierKey(forKeyCode code: UInt16) -> NSEvent.ModifierFlags? {
        switch code {
        case 56, 60: return .shift
        case 59, 62: return .control
        case 58, 61: return .option
        case 55, 54: return .command
        case 57: return .capsLock
        default: return nil
        }
    }

    /// For a `flagsChanged` on a right-side modifier key, whether that side is down. The generic
    /// flag (`.shift`, …) stays set while the left key is held, so only the device bit tells a
    /// right-side release apart. Left-side keys are not checked, as in Ghostty's macOS app.
    static func isSidePressed(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let bit: UInt
        switch keyCode {
        case 60: bit = deviceRightShift
        case 62: bit = deviceRightControl
        case 61: bit = deviceRightOption
        case 54: bit = deviceRightCommand
        default: return true
        }
        return flags.rawValue & bit != 0
    }
}
