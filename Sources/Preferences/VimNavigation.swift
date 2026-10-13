import Foundation

/// Vim-style navigation: ⌥H/J/K/L focus the pane in that direction, ⌥⇧J/K go to the next and
/// previous tab. Fixed keys (Settings only turns them off), taken before the terminal sees them.
public enum VimNavigation {
    public enum Direction: Equatable, Sendable { case left, down, up, right }

    public enum Command: Equatable, Sendable {
        case focusPane(Direction)
        case nextTab
        case previousTab
    }

    /// `key` is the key's character without modifiers but Shift (`charactersIgnoringModifiers`),
    /// so it follows the keyboard layout's letters.
    public static func command(key: String, modifiers: Shortcut.Modifiers) -> Command? {
        guard modifiers.contains(.option), modifiers.isDisjoint(with: [.command, .control]) else { return nil }
        let letter = key.lowercased()
        if modifiers.contains(.shift) {
            switch letter {
            case "j": return .nextTab
            case "k": return .previousTab
            default: return nil
            }
        }
        switch letter {
        case "h": return .focusPane(.left)
        case "j": return .focusPane(.down)
        case "k": return .focusPane(.up)
        case "l": return .focusPane(.right)
        default: return nil
        }
    }
}
