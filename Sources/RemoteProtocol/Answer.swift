import Foundation

// Answering an agent that waits for permission, from another device: the pane's `prompt` says what
// it asks and its choices; `answer` presses a key in the pane, as the user would at the Mac.

extension RemoteProtocol.Method {
    /// Presses a key in a pane that waits for permission (`AnswerParams` → `AnswerResult`); a pane
    /// that doesn't is refused (`RemoteError.notWaiting`).
    public static let answer = "answer"
}

extension RemoteError {
    /// `answer` to a pane whose agent waits for nothing.
    public static let notWaiting = -32004
}

/// What an agent waiting for permission asks, as its screen shows it.
public struct RemotePrompt: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Sendable {
        /// The key that picks it: `answer`'s `key` ("1").
        public var key: String
        public var label: String

        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }

    /// "Bash command".
    public var title: String?
    /// What it wants to run or change.
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

public struct AnswerParams: Codable, Equatable, Sendable {
    /// The pane, by id, id suffix or label, as `-p` names one.
    public var pane: String
    /// "return", "escape", "y", "n", "interrupt" or a digit.
    public var key: String

    public init(pane: String, key: String) {
        self.pane = pane
        self.key = key
    }

    public static let keys = Set(["return", "escape", "y", "n", "interrupt"] + (0...9).map(String.init))
}

public struct AnswerResult: Codable, Equatable, Sendable {
    public var pane: String

    public init(pane: String) {
        self.pane = pane
    }
}
