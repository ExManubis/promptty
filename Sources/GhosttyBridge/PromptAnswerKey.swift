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
