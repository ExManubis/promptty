import Foundation

/// Reads zsh's history file.
///
/// Each entry is either a plain line or, with `EXTENDED_HISTORY`, `: <start>:<duration>;<command>`.
/// A newline inside a command is written as a backslash at the end of the line. zsh also
/// "metafies" some bytes: `0x83` followed by the original byte xor `0x20`.
public enum ZshHistory {
    /// Oldest first.
    public static func parse(_ data: Data) -> [String] {
        let text = String(decoding: unmetafy(data), as: UTF8.self)
        var entries: [String] = []
        var pending: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasSuffix("\\") {
                pending.append(line.dropLast())
                continue
            }
            pending.append(line)
            let joined = pending.joined(separator: "\n")
            pending = []
            let command = stripExtendedHeader(joined)
            if !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { entries.append(command) }
        }
        if !pending.isEmpty {
            let command = stripExtendedHeader(pending.joined(separator: "\n"))
            if !command.isEmpty { entries.append(command) }
        }
        return entries
    }

    private static func unmetafy(_ data: Data) -> Data {
        guard data.contains(0x83) else { return data }
        var out = Data(capacity: data.count)
        var meta = false
        for byte in data {
            if meta {
                out.append(byte ^ 0x20)
                meta = false
            } else if byte == 0x83 {
                meta = true
            } else {
                out.append(byte)
            }
        }
        return out
    }

    /// `: 1700000000:0;cmd` → `cmd`; anything else is returned unchanged.
    private static func stripExtendedHeader(_ entry: String) -> String {
        guard entry.hasPrefix(": "), let semicolon = entry.firstIndex(of: ";") else { return entry }
        let header = entry[entry.index(entry.startIndex, offsetBy: 2)..<semicolon]
        let parts = header.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return entry }
        return String(entry[entry.index(after: semicolon)...])
    }
}

/// The commands the bar offers: the history file's, with this session's on top. Newest first,
/// each command once.
public struct CommandHistory: Sendable {
    private var fileEntries: [String]
    private var sessionEntries: [String] = []

    public init(fileEntries: [String]) {
        self.fileEntries = fileEntries
    }

    public mutating func add(_ command: String) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sessionEntries.append(command)
    }

    /// The file changed on disk (zsh appends as commands run).
    public mutating func replaceFileEntries(_ entries: [String]) {
        fileEntries = entries
    }

    public var newestFirst: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for command in (fileEntries + sessionEntries).reversed() where seen.insert(command).inserted {
            result.append(command)
        }
        return result
    }
}

/// Walks a history list from the text being edited (the draft) to older entries and back.
public struct HistoryNavigator: Sendable {
    private let history: [String]
    /// -1 is the draft; 0 the newest entry.
    private var index = -1
    public private(set) var draft: String?

    public init(history: [String]) {
        self.history = history
    }

    public var isBrowsing: Bool { index >= 0 }

    /// The next older entry, or nil when there is none. `current` is kept as the draft when leaving it.
    public mutating func older(current: String) -> String? {
        guard index + 1 < history.count else { return nil }
        if index == -1 { draft = current }
        index += 1
        return history[index]
    }

    /// The next newer entry, the draft after the newest, or nil when already at the draft.
    public mutating func newer() -> String? {
        guard index >= 0 else { return nil }
        index -= 1
        return index == -1 ? (draft ?? "") : history[index]
    }
}
