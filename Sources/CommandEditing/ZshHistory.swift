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

/// Commands in the order they were added, each once: adding one that is already there moves it to
/// the newest position. Older copies are left as holes and skipped on read, so adding is O(1);
/// the holes are squeezed out once they outnumber the entries.
public struct HistoryLayer: Sendable {
    private var entries: [String?] = []
    private var positions: [String: Int] = [:]

    public init() {}

    public init(_ commands: [String]) {
        entries.reserveCapacity(commands.count)
        for command in commands { append(command) }
    }

    public var isEmpty: Bool { positions.isEmpty }

    public func contains(_ command: String) -> Bool { positions[command] != nil }

    public mutating func append(_ command: String) {
        if let old = positions[command] { entries[old] = nil }
        positions[command] = entries.count
        entries.append(command)
        if entries.count > 2 * positions.count + 32 { squeeze() }
    }

    /// Newest first.
    public var newestFirst: [String] { entries.reversed().compactMap { $0 } }

    /// Oldest first.
    public var oldestFirst: [String] { entries.compactMap { $0 } }

    fileprivate func forEachNewestFirst(_ body: (String) -> Void) {
        for entry in entries.reversed() { if let entry { body(entry) } }
    }

    private mutating func squeeze() {
        entries = entries.filter { $0 != nil }
        for (offset, entry) in entries.enumerated() { positions[entry!] = offset }
    }
}

/// The commands the bar offers: the history file's, with this session's on top. Newest first,
/// each command once. One instance is shared by the panes using the same history file (see
/// `HistoryStore`), so it is a reference type; it is not thread-safe.
public final class CommandHistory {
    private var file: HistoryLayer
    private var session = HistoryLayer()
    private var cached: [String]?
    /// Changes whenever `newestFirst` does, for callers that keep results derived from it.
    public private(set) var version = 0

    /// Read on every keystroke (ghost text, history). Built on the first read after a change, so
    /// a burst of changes costs one pass.
    public var newestFirst: [String] {
        if let cached { return cached }
        var result: [String] = []
        session.forEachNewestFirst { result.append($0) }
        file.forEachNewestFirst { if !session.contains($0) { result.append($0) } }
        cached = result
        return result
    }

    public init(fileEntries: [String] = []) {
        file = HistoryLayer(fileEntries)
    }

    /// What this session added, oldest first.
    public var sessionCommands: [String] { session.oldestFirst }

    /// A command starting with a space stays out, as zsh's `HIST_IGNORE_SPACE` keeps it out of the
    /// history file (people use it for commands with secrets).
    public func add(_ command: String) {
        guard !command.hasPrefix(" "), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.append(command)
        changed()
    }

    /// The file changed on disk in a way that is not just growth.
    public func replaceFileEntries(_ entries: [String]) {
        replaceFile(HistoryLayer(entries))
    }

    /// Same, with the de-duplication already done (off the main thread).
    public func replaceFile(_ layer: HistoryLayer) {
        file = layer
        changed()
    }

    /// The file grew (zsh appends as commands run): `entries` are newer than everything it had.
    public func appendFileEntries(_ entries: [String]) {
        guard !entries.isEmpty else { return }
        for entry in entries { file.append(entry) }
        changed()
    }

    private func changed() {
        cached = nil
        version += 1
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
