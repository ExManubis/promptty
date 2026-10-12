/// Ghost-text suggestions, as zsh-autosuggestions' default strategy: the newest history entry that
/// starts with what has been typed.
public enum Autosuggester {
    /// The text to show after `text`, or nil.
    public static func suggestion(for text: String, history newestFirst: [String]) -> String? {
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        guard let match = newestFirst.first(where: { $0.count > text.count && $0.hasPrefix(text) }) else { return nil }
        return String(match.dropFirst(text.count))
    }

    /// The part of a suggestion ⌥→ accepts: leading spaces plus one word.
    public static func firstWord(of suggestion: String) -> String {
        let spaces = suggestion.prefix(while: { $0 == " " })
        let word = suggestion.dropFirst(spaces.count).prefix(while: { $0 != " " })
        return String(spaces) + String(word)
    }
}
