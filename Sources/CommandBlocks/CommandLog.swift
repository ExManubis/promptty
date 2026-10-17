import Foundation

/// A command run in a pane, as `promptty` reports it: an id that stays the same while the
/// scrollback moves (the terminal only knows its blocks by row), what was run, and how it ended.
public struct CommandRecord: Equatable, Sendable {
    /// `cmd:` and a UUID.
    public let id: String
    public let command: String
    public let started: Date
    public internal(set) var finished: Date?
    /// Nil while it runs, or when the shell did not report one.
    public internal(set) var exitCode: Int?
    /// Its place among every command the pane has run, from 0.
    public let ordinal: Int

    public var running: Bool { finished == nil }

    /// A command handed an id that has not started yet (its pane's shell is still starting).
    public static func pending(id: String, command: String, at date: Date = Date()) -> CommandRecord {
        CommandRecord(id: id, command: command, started: date, finished: nil, exitCode: nil, ordinal: -1)
    }

    /// Not started yet: no block to read.
    public var pending: Bool { ordinal < 0 }
}

/// A pane's recent commands, newest last.
public struct CommandLog: Equatable, Sendable {
    public private(set) var records: [CommandRecord] = []
    /// How many commands the pane has run, the forgotten ones included.
    public private(set) var count = 0
    public static let limit = 100
    public static let prefix = "cmd:"

    public init() {}

    public static func newID() -> String { prefix + UUID().uuidString.lowercased() }

    /// A command starts; `id` is one handed out before it ran (a new tab's command), else a new one.
    /// Returns its id, and the commands still marked running that it ended: they never reported
    /// their end (the shell was replaced), so they are over now, without an exit code.
    @discardableResult
    public mutating func start(_ command: String, id: String? = nil, at date: Date = Date()) -> (id: String, ended: [CommandRecord]) {
        var ended: [CommandRecord] = []
        for i in records.indices where records[i].running {
            records[i].finished = date
            ended.append(records[i])
        }
        let id = id ?? Self.newID()
        records.append(CommandRecord(id: id, command: command, started: date, finished: nil, exitCode: nil, ordinal: count))
        count += 1
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
        return (id, ended)
    }

    /// The running command ended; returns it, or nil when none was running.
    @discardableResult
    public mutating func finish(code: Int?, at date: Date = Date()) -> CommandRecord? {
        guard let i = records.lastIndex(where: { $0.running }) else { return nil }
        records[i].finished = date
        records[i].exitCode = code.flatMap { $0 < 0 ? nil : $0 }
        return records[i]
    }

    public func record(_ id: String) -> CommandRecord? {
        records.last { $0.id == id }
    }

    /// Which of the terminal's blocks (their commands, oldest first; nil where unreadable) is
    /// `record`'s. Each command makes one block, so it is as far from the newest block as the record
    /// is from the newest record; the commands' text confirms it, looking a few blocks either side
    /// for one a command not run from the bar may have added.
    public func blockIndex(of record: CommandRecord, commands: [String?]) -> Int? {
        guard !record.pending else { return nil }
        let expected = commands.count - 1 - (count - 1 - record.ordinal)
        let wanted = Self.normalized(record.command)
        for offset in [0, -1, 1, -2, 2, -3, 3] {
            let i = expected + offset
            guard commands.indices.contains(i), let text = commands[i], Self.normalized(text) == wanted else { continue }
            return i
        }
        return nil
    }

    /// Whitespace runs as one space, ends trimmed: the terminal's copy of a long command is wrapped.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
