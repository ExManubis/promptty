import Foundation

/// Where completion candidates come from. The app implements it over the file system, git and the
/// shell's state file; tests use fakes.
public protocol CompletionSources: Sendable {
    /// Aliases, functions, builtins, reserved words and executables on the shell's PATH.
    func commandNames() -> Set<String>
    func exportNames() -> Set<String>
    func entries(inDirectory path: String) -> [(name: String, isDirectory: Bool)]
    func gitBranches(in directory: String) -> [String]
}

public struct Completion: Equatable, Sendable {
    /// The UTF-16 range of the text the candidates replace (the word up to the caret).
    public var replacement: Range<Int>
    /// Each a full replacement for that range, sorted.
    public var candidates: [String]
    /// What every candidate starts with; inserted first when there are several.
    public var commonPrefix: String

    /// With one candidate: the text to insert, with a space after anything but a directory.
    public var singleInsertion: String? {
        guard candidates.count == 1, let only = candidates.first else { return nil }
        return only.hasSuffix("/") ? only : only + " "
    }
}

/// Tab completion for the input bar: command names, `$` variables, git subcommands and branches,
/// and paths relative to the pane's directory.
public enum CompletionEngine {
    public static func complete(text: String, cursor: Int, directory: String, home: String, sources: CompletionSources) -> Completion? {
        let units = Array(text.utf16)
        let end = min(cursor, units.count)
        let start = wordStart(units, before: end)
        let word = String(decoding: units[start..<end], as: UTF16.self)
        let before = String(decoding: units[..<start], as: UTF16.self)
        let commandWords = wordsOfCurrentCommand(before)

        let candidates: [String]
        if word.hasPrefix("$") {
            let prefix = String(word.dropFirst())
            candidates = sources.exportNames().filter { $0.hasPrefix(prefix) }.map { "$" + $0 }
        } else if commandWords.isEmpty, !word.contains("/"), !word.hasPrefix("~") {
            candidates = sources.commandNames().filter { $0.hasPrefix(word) }.map { $0 }
        } else if commandWords.first == "git", let git = gitCandidates(commandWords, word: word, directory: directory, sources: sources) {
            candidates = git
        } else {
            candidates = pathCandidates(word, directory: directory, home: home, sources: sources)
        }
        guard !candidates.isEmpty else { return nil }
        let sorted = Array(Set(candidates)).sorted()
        return Completion(replacement: start..<end, candidates: sorted, commonPrefix: commonPrefix(sorted))
    }

    // MARK: Words

    /// The start of the word ending at `end`: back to an unescaped blank or a shell operator.
    private static func wordStart(_ units: [UInt16], before end: Int) -> Int {
        var i = end
        while i > 0 {
            let c = units[i - 1]
            let escaped = i >= 2 && units[i - 2] == 92
            if !escaped, " \t\n|&;()<>".utf16.contains(c) { break }
            i -= 1
        }
        return i
    }

    /// The command's words before the one being completed (assignments skipped), or empty when the
    /// word is in command position.
    private static func wordsOfCurrentCommand(_ before: String) -> [String] {
        let units = Array(before.utf16)
        var words: [String] = []
        for token in CommandTokenizer.tokenize(before) {
            let text = String(decoding: units[token.range], as: UTF16.self)
            switch token.kind {
            case .op where !text.contains(">") && !text.contains("<"):
                words = []
            case .command, .flag, .string:
                words.append(text)
            case .argument where !words.isEmpty:
                words.append(text)
            default:
                continue
            }
        }
        return words
    }

    // MARK: git

    static let gitSubcommands = [
        "add", "am", "bisect", "blame", "branch", "checkout", "cherry", "cherry-pick", "clean", "clone", "commit",
        "config", "diff", "fetch", "grep", "init", "log", "merge", "mv", "pull", "push", "rebase", "reflog", "remote",
        "reset", "restore", "revert", "rm", "show", "stash", "status", "switch", "tag", "worktree",
    ]

    private static let branchSubcommands: Set<String> = ["checkout", "switch", "merge", "rebase"]

    private static func gitCandidates(_ words: [String], word: String, directory: String, sources: CompletionSources) -> [String]? {
        let args = words.dropFirst()
        let positional = args.filter { !$0.hasPrefix("-") }
        if positional.isEmpty, !word.hasPrefix("-") {
            return gitSubcommands.filter { $0.hasPrefix(word) }
        }
        guard let sub = positional.first, positional.count == 1 else { return nil }
        let wantsBranch = branchSubcommands.contains(sub) || (sub == "branch" && (args.contains("-d") || args.contains("-D")))
        guard wantsBranch else { return nil }
        return sources.gitBranches(in: directory).filter { $0.hasPrefix(word) }
    }

    // MARK: Paths

    private static func pathCandidates(_ word: String, directory: String, home: String, sources: CompletionSources) -> [String] {
        let typed = unescape(word)
        let slash = typed.lastIndex(of: "/")
        let typedDir = slash.map { String(typed[...$0]) } ?? ""
        let namePrefix = slash.map { String(typed[typed.index(after: $0)...]) } ?? typed
        var lookup = typedDir
        if lookup.hasPrefix("~") { lookup = home + lookup.dropFirst() }
        if !lookup.hasPrefix("/") { lookup = (directory as NSString).appendingPathComponent(lookup) }
        lookup = (lookup as NSString).standardizingPath
        let shownDir = escape(typedDir)
        return sources.entries(inDirectory: lookup)
            .filter { $0.name.hasPrefix(namePrefix) && (namePrefix.hasPrefix(".") || !$0.name.hasPrefix(".")) }
            .map { shownDir + escape($0.name) + ($0.isDirectory ? "/" : "") }
    }

    private static let special = Set(" \t'\"\\$&;|()<>*?[]#~`!{}")

    private static func escape(_ s: String) -> String {
        var out = ""
        for (i, ch) in s.enumerated() {
            // A leading ~ is the home shorthand, kept as typed.
            if special.contains(ch), !(ch == "~" && i == 0) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func unescape(_ s: String) -> String {
        var out = ""
        var escaped = false
        for ch in s {
            if !escaped, ch == "\\" { escaped = true; continue }
            out.append(ch)
            escaped = false
        }
        return out
    }

    private static func commonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for s in strings.dropFirst() {
            while !s.hasPrefix(prefix) { prefix.removeLast() }
        }
        return prefix
    }
}
