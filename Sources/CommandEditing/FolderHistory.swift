import Foundation

/// The commands run from the bar, with the folder each ran in: zsh's history does not record it.
/// Ghost text prefers what was run here, then in the folders above.
public struct FolderHistory: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let directory: String
        public let command: String
        public let date: Date

        public init(directory: String, command: String, date: Date) {
            self.directory = directory
            self.command = command
            self.date = date
        }
    }

    /// Oldest first.
    public private(set) var entries: [Entry] = []
    public static let limit = 5000

    public init(entries: [Entry] = []) {
        self.entries = Array(entries.suffix(Self.limit))
    }

    /// Records a command; one starting with a space stays private, as in zsh's history.
    @discardableResult
    public mutating func add(command: String, directory: String, date: Date) -> Entry? {
        guard !command.hasPrefix(" "), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let entry = Entry(directory: directory, command: command, date: date)
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        return entry
    }

    /// The commands to suggest in `directory`, best first: the ones run there, newest first, then
    /// those run in each folder above it, nearest first. Each command once.
    public func ranked(for directory: String) -> [String] {
        var chain: [String] = []
        var dir = directory
        while true {
            chain.append(dir)
            guard dir != "/" else { break }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        var byFolder: [String: [String]] = [:]
        let wanted = Set(chain)
        for entry in entries.reversed() where wanted.contains(entry.directory) {
            byFolder[entry.directory, default: []].append(entry.command)
        }
        var seen = Set<String>()
        var ranked: [String] = []
        for folder in chain {
            for command in byFolder[folder] ?? [] where seen.insert(command).inserted {
                ranked.append(command)
            }
        }
        return ranked
    }

    /// A folder worked in, for jumping back to it (⌘J).
    public struct Visited: Equatable, Sendable {
        public let directory: String
        public let commands: Int
        public let last: Date
    }

    /// The folders commands ran in, most used and most recent first, as zoxide ranks them: each
    /// command counts more the newer it is (4× in the last hour, 2× today, ½× this week, ¼× before).
    public func frecentFolders(now: Date, limit: Int = 200) -> [Visited] {
        var score: [String: Double] = [:]
        var count: [String: Int] = [:]
        var last: [String: Date] = [:]
        for entry in entries {
            let age = now.timeIntervalSince(entry.date)
            let weight: Double = age < 3600 ? 4 : age < 86400 ? 2 : age < 604_800 ? 0.5 : 0.25
            score[entry.directory, default: 0] += weight
            count[entry.directory, default: 0] += 1
            if last[entry.directory].map({ entry.date > $0 }) ?? true { last[entry.directory] = entry.date }
        }
        return score.keys
            .sorted { a, b in score[a]! != score[b]! ? score[a]! > score[b]! : last[a]! > last[b]! }
            .prefix(limit)
            .map { Visited(directory: $0, commands: count[$0]!, last: last[$0]!) }
    }

    /// One entry as a line of JSON, for appending to the history file.
    public static func line(for entry: Entry) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = (try? encoder.encode(entry)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The history file's lines; a line that does not read (a write cut short) is skipped.
    public static func decode(_ data: Data) -> FolderHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entries = data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
        return FolderHistory(entries: entries)
    }
}
