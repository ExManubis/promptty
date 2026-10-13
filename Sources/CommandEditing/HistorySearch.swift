import Foundation

/// Ctrl-R's search: the history fuzzy-filtered by what is typed, best first, at most `limit`
/// results. Built once when the picker opens (lowercasing 50k commands is not for each key);
/// `search` is then cheap, and narrows the last key's matches when the query only grew (a longer
/// query is matched by a subset of what the shorter one was).
public struct HistorySearch {
    public static let limit = 200
    /// What running a command in this folder (or one above it) adds to its score: above any
    /// fuzzy match, below a contiguous one.
    static let folderBonus = 500

    private let commands: [String]
    private let lowered: [[UInt8]]
    /// Where each command ranks among those run in the folder (nil: not run there).
    private let folderRank: [Int?]
    private var last: (query: [UInt8], matches: [Int])?

    /// `newestFirst`: the whole history. `folder`: the commands run in the folder and above it,
    /// best first (`FolderHistory.ranked`), or empty when nothing is known.
    public init(newestFirst: [String], folder: [String] = []) {
        var seen = Set<String>()
        var unique: [String] = []
        for command in newestFirst where seen.insert(command).inserted { unique.append(command) }
        commands = unique
        lowered = unique.map { Array($0.lowercased().utf8) }
        var ranks: [String: Int] = [:]
        for (rank, command) in folder.enumerated() where ranks[command] == nil { ranks[command] = rank }
        folderRank = unique.map { ranks[$0] }
    }

    public var isEmpty: Bool { commands.isEmpty }

    public mutating func search(_ query: String) -> [String] {
        let needle = Array(query.lowercased().utf8)
        let candidates: [Int]
        if let last, !last.query.isEmpty, needle.starts(with: last.query) {
            candidates = last.matches
        } else {
            candidates = Array(commands.indices)
        }
        var scored: [(index: Int, score: Int)] = []
        var matches: [Int] = []
        for index in candidates {
            guard let score = Self.score(needle, in: lowered[index]) else { continue }
            matches.append(index)
            scored.append((index, score + (folderRank[index] == nil ? 0 : Self.folderBonus)))
        }
        last = (needle, matches)
        // Best score first; equal scores keep the order given (newest first, folder's own first).
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return Self.order(a.index, b.index, folderRank)
        }
        return scored.prefix(Self.limit).map { commands[$0.index] }
    }

    /// With no query (or equal scores) the commands run in the folder come first, in their order,
    /// then the rest, newest first.
    private static func order(_ a: Int, _ b: Int, _ folderRank: [Int?]) -> Bool {
        switch (folderRank[a], folderRank[b]) {
        case let (x?, y?): x < y
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): a < b
        }
    }

    /// Nil when `needle` is not a subsequence of `text`. A contiguous match scores high (higher at
    /// the start, or at a word's start); otherwise the tighter the matched characters, the better.
    static func score(_ needle: [UInt8], in text: [UInt8]) -> Int? {
        guard !needle.isEmpty else { return 0 }
        guard needle.count <= text.count else { return nil }
        if let at = find(needle, in: text) {
            // Equal scores keep the order given, so of equal matches the newest comes first.
            if at == 0 { return 1200 }
            return isSeparator(text[at - 1]) ? 1100 : 1000
        }
        var next = 0
        var first = -1
        var end = 0
        for (offset, byte) in text.enumerated() where byte == needle[next] {
            if first < 0 { first = offset }
            next += 1
            if next == needle.count { end = offset; break }
        }
        guard next == needle.count else { return nil }
        // The span the characters cover: shorter is tighter.
        return 500 - min(end - first - needle.count + 1, 499)
    }

    private static func find(_ needle: [UInt8], in text: [UInt8]) -> Int? {
        let n = needle.count
        guard n <= text.count else { return nil }
        for start in 0...(text.count - n) where text[start] == needle[0] {
            var i = 1
            while i < n, text[start + i] == needle[i] { i += 1 }
            if i == n { return start }
        }
        return nil
    }

    private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x2F || byte == 0x2D || byte == 0x5F || byte == 0x2E
    }
}
