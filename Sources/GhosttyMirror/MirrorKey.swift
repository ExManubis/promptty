#if os(iOS)
import UIKit
import GhosttyKit

/// A key the phone sends that the on-screen keyboard has no key for, or that needs its key code
/// for the terminal to encode it (Return, arrows, a Control combination).
public enum MirrorKey: Sendable, Hashable {
    case `return`, tab, escape, backspace, forwardDelete
    case up, down, left, right, home, end, pageUp, pageDown
    /// A letter, digit or punctuation key on a US layout, unshifted (`c` for ⌃C).
    case character(Character)
}

/// Modifiers held with a `MirrorKey`.
public struct MirrorModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let shift = MirrorModifiers(rawValue: GHOSTTY_MODS_SHIFT.rawValue)
    public static let control = MirrorModifiers(rawValue: GHOSTTY_MODS_CTRL.rawValue)
    public static let option = MirrorModifiers(rawValue: GHOSTTY_MODS_ALT.rawValue)
    public static let command = MirrorModifiers(rawValue: GHOSTTY_MODS_SUPER.rawValue)

    init(_ flags: UIKeyModifierFlags) {
        var mods: MirrorModifiers = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.alternate) { mods.insert(.option) }
        if flags.contains(.command) { mods.insert(.command) }
        self = mods
    }

    var ghostty: ghostty_input_mods_e { ghostty_input_mods_e(rawValue: rawValue) }
}

/// libghostty takes the Mac's virtual key codes on iOS too (its keycodes table picks the mac
/// column for both). Pure conversions, no surface access.
enum MirrorKeyCodes {
    static func keyCode(_ key: MirrorKey) -> UInt32? {
        switch key {
        case .return: return 0x24
        case .tab: return 0x30
        case .escape: return 0x35
        case .backspace: return 0x33
        case .forwardDelete: return 0x75
        case .up: return 0x7E
        case .down: return 0x7D
        case .left: return 0x7B
        case .right: return 0x7C
        case .home: return 0x73
        case .end: return 0x77
        case .pageUp: return 0x74
        case .pageDown: return 0x79
        case .character(let c): return characterCodes[Character(c.lowercased())]
        }
    }

    /// A hardware keyboard's key (its HID usage) as a Mac key code.
    static func keyCode(_ usage: UIKeyboardHIDUsage) -> UInt32? {
        if let named = hidNamed[usage] { return named }
        // Letters, digits and the punctuation keys, by the character they type unshifted.
        switch usage.rawValue {
        case UIKeyboardHIDUsage.keyboardA.rawValue...UIKeyboardHIDUsage.keyboardZ.rawValue:
            let letter = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(usage.rawValue - UIKeyboardHIDUsage.keyboardA.rawValue)))
            return characterCodes[letter]
        case UIKeyboardHIDUsage.keyboard1.rawValue...UIKeyboardHIDUsage.keyboard9.rawValue:
            let digit = Character(UnicodeScalar(UInt8(ascii: "1") + UInt8(usage.rawValue - UIKeyboardHIDUsage.keyboard1.rawValue)))
            return characterCodes[digit]
        default:
            return hidPunctuation[usage].flatMap { characterCodes[$0] }
        }
    }

    private static let hidNamed: [UIKeyboardHIDUsage: UInt32] = [
        .keyboardReturnOrEnter: 0x24, .keypadEnter: 0x4C, .keyboardTab: 0x30, .keyboardEscape: 0x35,
        .keyboardDeleteOrBackspace: 0x33, .keyboardDeleteForward: 0x75, .keyboardSpacebar: 0x31,
        .keyboardUpArrow: 0x7E, .keyboardDownArrow: 0x7D, .keyboardLeftArrow: 0x7B, .keyboardRightArrow: 0x7C,
        .keyboardHome: 0x73, .keyboardEnd: 0x77, .keyboardPageUp: 0x74, .keyboardPageDown: 0x79,
        .keyboardF1: 0x7A, .keyboardF2: 0x78, .keyboardF3: 0x63, .keyboardF4: 0x76, .keyboardF5: 0x60,
        .keyboardF6: 0x61, .keyboardF7: 0x62, .keyboardF8: 0x64, .keyboardF9: 0x65, .keyboardF10: 0x6D,
        .keyboardF11: 0x67, .keyboardF12: 0x6F, .keyboard0: 0x1D,
    ]

    private static let hidPunctuation: [UIKeyboardHIDUsage: Character] = [
        .keyboardHyphen: "-", .keyboardEqualSign: "=", .keyboardOpenBracket: "[", .keyboardCloseBracket: "]",
        .keyboardBackslash: "\\", .keyboardSemicolon: ";", .keyboardQuote: "'", .keyboardGraveAccentAndTilde: "`",
        .keyboardComma: ",", .keyboardPeriod: ".", .keyboardSlash: "/",
    ]

    /// kVK_ANSI_* codes, by the character the key types unshifted on a US layout.
    private static let characterCodes: [Character: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32, " ": 0x31,
    ]

    /// The key code for a character the on-screen keyboard typed unshifted; nil for the rest
    /// (`A`, `!`, `é`), which the terminal gets as text alone.
    static func keyCode(typing c: Character) -> UInt32? {
        characterCodes[c]
    }
}
#endif
