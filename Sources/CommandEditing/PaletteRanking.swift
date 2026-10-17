import Foundation

/// The command palette's filter: which of its entries match what is typed, best first. An entry
/// matches by its title (fuzzily, as history search does) or, worth less, by its other words (a
/// tab's folder, a command's menu); with nothing typed every entry stays, in the order given.
public enum PaletteRanking {
    public struct Entry: Sendable {
        public var title: String
        public var keywords: String

        public init(title: String, keywords: String = "") {
            self.title = title
            self.keywords = keywords
        }
    }

    /// Indexes into `entries`, best first; equal scores keep the order given.
    public static func rank(_ query: String, _ entries: [Entry]) -> [Int] {
        let needle = Array(query.trimmingCharacters(in: .whitespaces).lowercased().utf8)
        guard !needle.isEmpty else { return Array(entries.indices) }
        var scored: [(index: Int, score: Int)] = []
        for (index, entry) in entries.enumerated() {
            let title = HistorySearch.score(needle, in: Array(entry.title.lowercased().utf8))
            // Below any match of the title.
            let other = HistorySearch.score(needle, in: Array(entry.keywords.lowercased().utf8)).map { $0 - 1300 }
            guard let score = [title, other].compactMap({ $0 }).max() else { continue }
            scored.append((index, score))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.index)
    }
}
