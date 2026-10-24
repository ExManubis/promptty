import Foundation

/// The keys that answer a program's prompt for a choice, as Claude Code's permission prompt asks
/// for one: Return, Esc, y or n, a digit, ⌃C. Moving through the choices (arrows, Tab) does not.
public enum PromptAnswerKey {
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53

    /// `characters` as typed without modifiers (`charactersIgnoringModifiers`).
    public static func answers(keyCode: UInt16, characters: String?, command: Bool, control: Bool) -> Bool {
        guard !command else { return false }
        if [returnKey, keypadEnter, escape].contains(keyCode) { return true }
        guard let characters, characters.count == 1, let c = characters.lowercased().first else { return false }
        if control { return c == "c" }
        return c == "y" || c == "n" || c.isASCII && c.isNumber
    }
}

/// A key that answers a prompt, pressed from elsewhere (the remote API): the keys
/// `PromptAnswerKey` counts as answers, nothing else, so an answer cannot type into a shell.
public enum PromptKey: Equatable, Sendable {
    case `return`
    case escape
    case yes
    case no
    /// 0 to 9.
    case digit(Int)
    /// ⌃C.
    case interrupt

    /// "return", "escape", "y", "n", "1"… "9", "0", "interrupt".
    public init?(name: String) {
        switch name {
        case "return": self = .return
        case "escape": self = .escape
        case "y": self = .yes
        case "n": self = .no
        case "interrupt": self = .interrupt
        default:
            guard name.count == 1, let digit = Int(name) else { return nil }
            self = .digit(digit)
        }
    }

    /// The macOS virtual key codes of the digits, 0 to 9.
    static let digitCodes: [UInt32] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
}

