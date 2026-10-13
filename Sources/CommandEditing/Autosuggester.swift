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
/// look at (usually) one entry rather than the whole history. The lists are scanned in order:
/// this folder's, the pane's own commands, the history file's (an entry of the file that the pane
/// also ran gives the same suggestion from the earlier list).
public struct IncrementalSuggester {
    private enum Scan {
        case exhausted
        case found(Int)
    }

    private var text = ""
    private var generation = 0
    private var scans: [Scan?] = [nil, nil, nil]
    private var started = false
    private var result: String?
    /// How many entries were looked at since creation; for tests.
    public private(set) var scanCount = 0

    public init() {}

    public mutating func suggestion(for text: String, local: [String], history: [String], generation: Int) -> String? {
        suggestion(for: text, local: local, history: MergedHistory(newestFirst: history), generation: generation)
    }

    /// `generation` identifies the lists: when it differs from the last call's, they may have
    /// changed and everything is scanned afresh.
    public mutating func suggestion(for text: String, local: [String], history: MergedHistory, generation: Int) -> String? {
        guard !text.isEmpty, !text.contains("\n") else {
            reset(to: text, generation: generation)
            return nil
        }
        if started, generation == self.generation, text == self.text { return result }
        let extends = started && generation == self.generation && !self.text.isEmpty && text.hasPrefix(self.text)
        if !extends { reset(to: text, generation: generation) }
        started = true
        self.text = text
        let lists = [local, history.session, history.file]
        var found: String?
        for tier in 0..<3 {
            found = Self.scan(text, in: lists[tier], state: &scans[tier], count: &scanCount)
            if found != nil { break }
        }
        result = found
        return found
    }

    private mutating func reset(to text: String, generation: Int) {
        self.text = text
        self.generation = generation
        scans = [nil, nil, nil]
        started = false
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
