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

/// What `complete` will read from the file system or git, so the app can fetch it off the main
/// thread first and hand the engine a `CompletionSnapshot`.
public enum CompletionNeed: Hashable, Sendable {
    /// The entries of this (standardized, absolute) directory.
    case directory(String)
    /// The local branches of the repository at this directory.
    case gitBranches(String)
}

/// Completion sources over data fetched ahead of time: nothing here touches the disk, so filtering
/// it per keystroke is cheap. Directories and repositories not fetched read as empty.
public struct CompletionSnapshot: CompletionSources {
    public var commands: Set<String>
    public var exports: Set<String>
    public var listings: [String: [(name: String, isDirectory: Bool)]] = [:]
    public var branches: [String: [String]] = [:]

    public init(commands: Set<String>, exports: Set<String>) {
        self.commands = commands
        self.exports = exports
    }

    /// Whether `need` has been fetched.
    public func has(_ need: CompletionNeed) -> Bool {
        switch need {
        case .directory(let path): listings[path] != nil
        case .gitBranches(let directory): branches[directory] != nil
        }
    }

    public func commandNames() -> Set<String> { commands }
    public func exportNames() -> Set<String> { exports }
    public func entries(inDirectory path: String) -> [(name: String, isDirectory: Bool)] { listings[path] ?? [] }
    public func gitBranches(in directory: String) -> [String] { branches[directory] ?? [] }
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
    /// What kind of word is being completed.
    private enum Kind {
        case exports(prefix: String)
        case commands(word: String)
        case gitSubcommands(word: String)
        case gitBranches(word: String)
        case paths(word: String)
    }

    private struct Analysis {
        var start: Int
        var end: Int
        var kind: Kind
    }

    private static func analyze(text: String, cursor: Int) -> Analysis {
        let units = Array(text.utf16)
        let end = min(cursor, units.count)
        let start = wordStart(units, before: end)
        let word = String(decoding: units[start..<end], as: UTF16.self)
        let before = String(decoding: units[..<start], as: UTF16.self)
        let commandWords = wordsOfCurrentCommand(before)

        let kind: Kind
        if word.hasPrefix("$") {
            kind = .exports(prefix: String(word.dropFirst()))
        } else if commandWords.isEmpty, !word.contains("/"), !word.hasPrefix("~") {
            kind = .commands(word: word)
        } else if commandWords.first == "git", let git = gitKind(commandWords, word: word) {
            kind = git
        } else {
            kind = .paths(word: word)
        }
        return Analysis(start: start, end: end, kind: kind)
    }

    /// The disk or git data `complete` will read for this text, nil when it reads none.
    public static func need(text: String, cursor: Int, directory: String, home: String) -> CompletionNeed? {
        switch analyze(text: text, cursor: cursor).kind {
        case .gitBranches: .gitBranches(directory)
        case .paths(let word): .directory(lookupDirectory(word, directory: directory, home: home))
        case .exports, .commands, .gitSubcommands: nil
        }
    }

    public static func complete(text: String, cursor: Int, directory: String, home: String, sources: CompletionSources) -> Completion? {
        let analysis = analyze(text: text, cursor: cursor)
        let candidates: [String]
        switch analysis.kind {
        case .exports(let prefix):
            candidates = sources.exportNames().filter { $0.hasPrefix(prefix) }.map { "$" + $0 }
        case .commands(let word):
            candidates = sources.commandNames().filter { $0.hasPrefix(word) }.map { $0 }
        case .gitSubcommands(let word):
            candidates = gitSubcommands.filter { $0.hasPrefix(word) }
        case .gitBranches(let word):
            candidates = sources.gitBranches(in: directory).filter { $0.hasPrefix(word) }
        case .paths(let word):
            candidates = pathCandidates(word, directory: directory, home: home, sources: sources)
        }
        guard !candidates.isEmpty else { return nil }
        let sorted = Array(Set(candidates)).sorted()
        return Completion(replacement: analysis.start..<analysis.end, candidates: sorted, commonPrefix: commonPrefix(sorted))
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

    private static func gitKind(_ words: [String], word: String) -> Kind? {
        let args = words.dropFirst()
        let positional = args.filter { !$0.hasPrefix("-") }
        if positional.isEmpty, !word.hasPrefix("-") {
            return .gitSubcommands(word: word)
        }
        guard let sub = positional.first, positional.count == 1 else { return nil }
        let wantsBranch = branchSubcommands.contains(sub) || (sub == "branch" && (args.contains("-d") || args.contains("-D")))
        guard wantsBranch else { return nil }
        return .gitBranches(word: word)
    }

    // MARK: Paths

    /// The part of a typed path up to and including its last `/` (unescaped), and what follows.
    private static func splitPath(_ word: String) -> (typedDir: String, namePrefix: String) {
        let typed = unescape(word)
        let slash = typed.lastIndex(of: "/")
        return (slash.map { String(typed[...$0]) } ?? "", slash.map { String(typed[typed.index(after: $0)...]) } ?? typed)
    }

    /// The absolute, standardized directory whose entries complete `word`.
    private static func lookupDirectory(_ word: String, directory: String, home: String) -> String {
        var lookup = splitPath(word).typedDir
        if lookup.hasPrefix("~") { lookup = home + lookup.dropFirst() }
        if !lookup.hasPrefix("/") { lookup = (directory as NSString).appendingPathComponent(lookup) }
        return (lookup as NSString).standardizingPath
    }

    private static func pathCandidates(_ word: String, directory: String, home: String, sources: CompletionSources) -> [String] {
        let (typedDir, namePrefix) = splitPath(word)
        let lookup = lookupDirectory(word, directory: directory, home: home)
        let shownDir = ShellQuoting.escape(typedDir)
        return sources.entries(inDirectory: lookup)
            .filter { $0.name.hasPrefix(namePrefix) && (namePrefix.hasPrefix(".") || !$0.name.hasPrefix(".")) }
            .map { shownDir + ShellQuoting.escape($0.name) + ($0.isDirectory ? "/" : "") }
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
