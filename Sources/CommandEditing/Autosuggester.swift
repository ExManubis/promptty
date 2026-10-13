/// Ghost-text suggestions, as zsh-autosuggestions' default strategy: the newest history entry that
/// starts with what has been typed.
public enum Autosuggester {
    /// The text to show after `text`, or nil.
    public static func suggestion(for text: String, history newestFirst: [String]) -> String? {
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        // UTF-16 lengths: `String.count` walks the whole string, and this runs over the whole
        // history on every keystroke.
        let length = text.utf16.count
        guard let match = newestFirst.first(where: { $0.utf16.count > length && $0.hasPrefix(text) }) else { return nil }
        return String(match.dropFirst(text.count))
    }

    /// This folder's commands first (`local`, best first), then the whole history.
    public static func suggestion(for text: String, local: [String], history newestFirst: [String]) -> String? {
        suggestion(for: text, history: local) ?? suggestion(for: text, history: newestFirst)
    }

    /// The part of a suggestion ⌥→ accepts: leading spaces plus one word.
    public static func firstWord(of suggestion: String) -> String {
        let spaces = suggestion.prefix(while: { $0 == " " })
        let word = suggestion.dropFirst(spaces.count).prefix(while: { $0 != " " })
        return String(spaces) + String(word)
    }
}

/// `Autosuggester.suggestion(for:local:history:)` for text typed one key at a time. A scan that
/// found nothing for some text finds nothing for any extension of it, and one that found a
/// match at an index skips everything before that index for an extension, so each key costs a
/// look at (usually) one entry rather than the whole history.
public struct IncrementalSuggester {
    private enum Scan {
        case exhausted
        case found(Int)
    }

    private var text = ""
    private var generation = 0
    private var local: Scan?
    private var history: Scan?
    private var result: String?
    /// How many history entries were looked at since creation; for tests.
    public private(set) var scanCount = 0

    public init() {}

    /// `generation` identifies the lists: when it differs from the last call's, they may have
    /// changed and everything is scanned afresh.
    public mutating func suggestion(for text: String, local: [String], history: [String], generation: Int) -> String? {
        guard !text.isEmpty, !text.contains("\n") else {
            reset(to: text, generation: generation)
            return nil
        }
        if generation == self.generation, text == self.text, self.local != nil { return result }
        let extends = generation == self.generation && !self.text.isEmpty && text.hasPrefix(self.text)
        if !extends { reset(to: text, generation: generation) }
        self.text = text
        let found: String?
        if let match = Self.scan(text, in: local, state: &self.local, count: &scanCount) {
            found = match
        } else {
            found = Self.scan(text, in: history, state: &self.history, count: &scanCount)
        }
        result = found
        return found
    }

    private mutating func reset(to text: String, generation: Int) {
        self.text = text
        self.generation = generation
        local = nil
        history = nil
        result = nil
    }

    private static func scan(_ text: String, in list: [String], state: inout Scan?, count: inout Int) -> String? {
        let start: Int
        switch state {
        case .exhausted?: return nil
        case .found(let index)?: start = index
        case nil: start = 0
        }
        let length = text.utf16.count
        var index = start
        while index < list.count {
            count += 1
            let entry = list[index]
            if entry.utf16.count > length && entry.hasPrefix(text) {
                state = .found(index)
                return String(entry.dropFirst(text.count))
            }
            index += 1
        }
        state = .exhausted
        return nil
    }
}
