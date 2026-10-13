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

/// The history as the bar walks it, newest first, each command once: a pane's own commands, then
/// the file's that are not among them. A view over two lists, so making one is O(1) and walking
/// it costs only as far as it goes.
public struct MergedHistory: Sequence, Sendable {
    public let session: [String]
    public let file: [String]
    private let shadowed: HistoryLayer

    public init(session: [String], file: [String], shadowed: HistoryLayer) {
        self.session = session
        self.file = file
        self.shadowed = shadowed
    }

    public init(newestFirst: [String]) {
        self.init(session: [], file: newestFirst, shadowed: HistoryLayer())
    }

    public func makeIterator() -> Iterator { Iterator(self) }

    public struct Iterator: IteratorProtocol {
        private let merged: MergedHistory
        private var index = 0
        private var inFile = false

        fileprivate init(_ merged: MergedHistory) { self.merged = merged }

        public mutating func next() -> String? {
            if !inFile {
                if index < merged.session.count {
                    defer { index += 1 }
                    return merged.session[index]
                }
                inFile = true
                index = 0
            }
            while index < merged.file.count {
                let entry = merged.file[index]
                index += 1
                if !merged.shadowed.contains(entry) { return entry }
            }
            return nil
        }
    }
}

/// What the bar offers one pane: the history file's commands (shared with the panes using the
/// same HISTFILE, see `HistoryStore`) with this pane's own on top. Newest first, each command once.
@MainActor
public final class CommandHistory {
    public private(set) var store: HistoryStore
    private var session = HistoryLayer()
    private var sessionCached: [String]?
    private var sessionVersion = 0
    /// How many times the whole list was merged into one array; for tests.
    private(set) var mergeCount = 0

    public init(store: HistoryStore = HistoryStore()) {
        self.store = store
    }

    public convenience init(fileEntries: [String]) {
        self.init(store: HistoryStore(entries: fileEntries))
    }

    /// The pane learned its HISTFILE: the file's commands change, its own stay.
    public func use(_ store: HistoryStore) {
        guard store !== self.store else { return }
        self.store = store
        sessionVersion += 1
    }

    /// Changes whenever what the bar offers may have.
    public var version: Int {
        var hasher = Hasher()
        hasher.combine(ObjectIdentifier(store))
        hasher.combine(store.version)
        hasher.combine(sessionVersion)
        return hasher.finalize()
    }

    /// Ready to walk or scan. Cheap: nothing is merged.
    public var merged: MergedHistory {
        if sessionCached == nil { sessionCached = session.newestFirst }
        return MergedHistory(session: sessionCached ?? [], file: store.newestFirst, shadowed: session)
    }

    /// Everything as one array, which costs a pass over the whole history: for a search, not for
    /// each key.
    public var newestFirst: [String] {
        mergeCount += 1
        return Array(merged)
    }

    /// What this pane added, oldest first.
    public var sessionCommands: [String] { session.oldestFirst }

    /// A command starting with a space stays out, as zsh's `HIST_IGNORE_SPACE` keeps it out of the
    /// history file (people use it for commands with secrets).
    public func add(_ command: String) {
        guard !command.hasPrefix(" "), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.append(command)
        sessionCached = nil
        sessionVersion += 1
    }

    /// The file changed on disk in a way that is not just growth (own store only: tests).
    public func replaceFileEntries(_ entries: [String]) { store.replaceFile(entries) }

    /// The file grew (own store only: tests).
    public func appendFileEntries(_ entries: [String]) { store.appendFile(entries) }
}

/// Walks a history list from the text being edited (the draft) to older entries and back.
/// Older entries are taken from the source only as the walk reaches them.
public struct HistoryNavigator {
    private var loaded: [String]
    private var source: MergedHistory.Iterator?
    /// -1 is the draft; 0 the newest entry.
    private var index = -1
    public private(set) var draft: String?

    public init(history: [String]) {
        loaded = history
    }

    public init(history: MergedHistory) {
        loaded = []
        source = history.makeIterator()
    }

    public var isBrowsing: Bool { index >= 0 }

    private mutating func entry(at position: Int) -> String? {
        while loaded.count <= position, source != nil {
            if let next = source?.next() { loaded.append(next) } else { source = nil }
        }
        return position < loaded.count ? loaded[position] : nil
    }

    /// The next older entry, or nil when there is none. `current` is kept as the draft when leaving it.
    public mutating func older(current: String) -> String? {
        guard let entry = entry(at: index + 1) else { return nil }
        if index == -1 { draft = current }
        index += 1
        return entry
    }

    /// The next newer entry, the draft after the newest, or nil when already at the draft.
    public mutating func newer() -> String? {
        guard index >= 0 else { return nil }
        index -= 1
        return index == -1 ? (draft ?? "") : loaded[index]
    }
}
