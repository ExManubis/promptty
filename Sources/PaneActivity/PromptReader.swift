import Foundation

/// A prompt for a choice, as an agent draws it on its screen: Claude Code's permission prompt is a
/// box with what it wants to do, a question, and numbered choices, the selected one marked `❯`.
public struct PermissionPrompt: Equatable, Sendable {
    public struct Choice: Equatable, Sendable {
        public var number: Int
        public var label: String
        public var selected: Bool

        public init(number: Int, label: String, selected: Bool = false) {
            self.number = number
            self.label = label
            self.selected = selected
        }
    }

    /// "Bash command".
    public var title: String?
    /// What it wants to run or change, as shown ("swift test --filter RemoteProtocol").
    public var detail: [String]
    /// "Do you want to proceed?"
    public var question: String
    public var choices: [Choice]

    public init(title: String?, detail: [String], question: String, choices: [Choice]) {
        self.title = title
        self.detail = detail
        self.question = question
        self.choices = choices
    }
}

/// Reads the prompt for a choice at the bottom of a screen (`PermissionPrompt`), for answering it
/// from another device: the choices become buttons there.
public enum PromptReader {
    public static func read(_ screen: String) -> PermissionPrompt? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(clean)
        // The last run of numbered choices on the screen.
        guard let last = lines.lastIndex(where: { choice($0) != nil }) else { return nil }
        var first = last
        while first > 0, choice(lines[first - 1]) != nil { first -= 1 }
        let choices = lines[first...last].compactMap(choice)
        guard choices.count >= 2, choices.first?.number == 1 else { return nil }
        // Above them: the question, and above it, up to the box's top, what is asked about.
        var index = first - 1
        while index >= 0, lines[index].isEmpty { index -= 1 }
        guard index >= 0 else { return nil }
        let question = lines[index]
        var above: [String] = []
        index -= 1
        // Blank lines inside the box don't end it; two in a row, outside one, do.
        while index >= 0, !isBorder(lines[index]), above.count < 8,
              !(lines[index].isEmpty && index > 0 && lines[index - 1].isEmpty) {
            if !lines[index].isEmpty { above.insert(lines[index], at: 0) }
            index -= 1
        }
        let title = above.first
        return PermissionPrompt(title: title, detail: Array(above.dropFirst()), question: question, choices: choices)
    }

    /// "❯ 1. Yes" or "  2. No": its number, label and whether it is selected.
    static func choice(_ line: String) -> PermissionPrompt.Choice? {
        var rest = Substring(line)
        let selected = rest.hasPrefix("❯") || rest.hasPrefix(">")
        if selected { rest = rest.dropFirst().drop(while: \.isWhitespace) }
        guard let dot = rest.firstIndex(of: "."), let number = Int(rest[..<dot]), (1...9).contains(number) else { return nil }
        let label = rest[rest.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return PermissionPrompt.Choice(number: number, label: label, selected: selected)
    }

    /// A line without the box drawn around it, trimmed.
    static func clean(_ line: Substring) -> String {
        var text = String(line).trimmingCharacters(in: .whitespaces)
        for edge in ["│", "┃", "|"] {
            if text.hasPrefix(edge) { text.removeFirst() }
            if text.hasSuffix(edge) { text.removeLast() }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func isBorder(_ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy { "─━╭╮╰╯┌┐└┘-".contains($0) }
    }
}
