/// What a piece of a command line is, for coloring.
public enum TokenKind: Equatable, Sendable {
    case command, argument, flag, string, variable, op, comment
}

/// `range` is in UTF-16 code units, as `NSString` and `NSTextView` count.
public struct Token: Equatable, Sendable {
    public var kind: TokenKind
    public var range: Range<Int>

    public init(kind: TokenKind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}

/// A small zsh-aware lexer. It does not parse: it knows words, quotes, variables, operators,
/// comments, and where a command name is expected (at the start, after `| && ; (` and newlines,
/// and after `NAME=value` assignments).
public enum CommandTokenizer {
    public static func tokenize(_ text: String) -> [Token] {
        var lexer = Lexer(units: Array(text.utf16))
        lexer.run()
        return lexer.tokens
    }
}

private struct Lexer {
    let units: [UInt16]
    var tokens: [Token] = []
    var i = 0
    var commandPosition = true

    init(units: [UInt16]) { self.units = units }

    mutating func run() {
        while i < units.count {
            let c = units[i]
            if c == .space || c == .tab || c == .carriageReturn {
                i += 1
            } else if c == .newline {
                commandPosition = true
                i += 1
            } else if c == .hash {
                let start = i
                while i < units.count, units[i] != .newline { i += 1 }
                tokens.append(Token(kind: .comment, range: start..<i))
            } else if let (length, redirect) = operatorAt(i) {
                tokens.append(Token(kind: .op, range: i..<(i + length)))
                if !redirect { commandPosition = true }
                i += length
            } else {
                word()
            }
        }
    }

    // MARK: Operators

    private static let operators: [(String, Bool)] = [
        ("&>>", true), ("||", false), ("&&", false), (";;", false), ("|&", false), ("&>", true), (">>", true),
        (">|", true), (">&", true), ("<<", true), ("<&", true), ("|", false), ("&", false), (";", false),
        ("(", false), (")", false), (">", true), ("<", true),
    ]

    /// The operator starting at `index` (its length, and whether it is a redirection). Digits right
    /// before `>`/`<` belong to the redirection (`2>`).
    private func operatorAt(_ index: Int) -> (Int, Bool)? {
        var j = index
        while j < units.count, units[j].isDigit { j += 1 }
        let digits = j - index
        if digits > 0, j < units.count, units[j] != .greater, units[j] != .less { return nil }
        for (op, redirect) in Self.operators {
            let opUnits = Array(op.utf16)
            guard j + opUnits.count <= units.count, Array(units[j..<(j + opUnits.count)]) == opUnits else { continue }
            if digits > 0, !redirect { return nil }
            return (digits + opUnits.count, redirect)
        }
        return nil
    }

    // MARK: Words

    private enum Role { case command, assignment, flag, argument }

    private mutating func word() {
        let role = roleOfWord(at: i)
        var plainStart: Int? = i
        var firstPlain = true

        func flushPlain(upTo end: Int, into tokens: inout [Token]) {
            guard let start = plainStart, start < end else { plainStart = nil; return }
            let kind: TokenKind
            switch role {
            case .command: kind = firstPlain ? .command : .argument
            case .flag: kind = .flag
            case .assignment, .argument: kind = .argument
            }
            tokens.append(Token(kind: kind, range: start..<end))
            firstPlain = false
            plainStart = nil
        }

        while i < units.count, !units[i].endsWord {
            let c = units[i]
            if c == .backslash {
                if plainStart == nil { plainStart = i }
                i = min(i + 2, units.count)
            } else if c == .singleQuote {
                flushPlain(upTo: i, into: &tokens)
                let start = i
                i += 1
                while i < units.count, units[i] != .singleQuote { i += 1 }
                i = min(i + 1, units.count)
                tokens.append(Token(kind: .string, range: start..<i))
                firstPlain = false
            } else if c == .doubleQuote {
                flushPlain(upTo: i, into: &tokens)
                doubleQuoted()
                firstPlain = false
            } else if c == .dollar, i + 1 < units.count, units[i + 1] == .singleQuote {
                flushPlain(upTo: i, into: &tokens)
                let start = i
                i += 2
                while i < units.count, units[i] != .singleQuote {
                    i += units[i] == .backslash ? 2 : 1
                }
                i = min(i + 1, units.count)
                tokens.append(Token(kind: .string, range: start..<i))
                firstPlain = false
            } else if c == .dollar, let end = variableEnd(at: i) {
                flushPlain(upTo: i, into: &tokens)
                tokens.append(Token(kind: .variable, range: i..<end))
                i = end
                firstPlain = false
            } else {
                if plainStart == nil { plainStart = i }
                i += 1
            }
        }
        flushPlain(upTo: i, into: &tokens)
        if role != .assignment { commandPosition = false }
    }

    /// A word's role from its first characters.
    private func roleOfWord(at start: Int) -> Role {
        if commandPosition {
            var j = start
            if j < units.count, units[j].isNameStart {
                while j < units.count, units[j].isNameChar { j += 1 }
                if j < units.count, units[j] == .equals { return .assignment }
            }
            return .command
        }
        return units[start] == .minus ? .flag : .argument
    }

    /// `"…"` from `i`, as string pieces around any variables inside.
    private mutating func doubleQuoted() {
        var pieceStart = i
        i += 1
        while i < units.count, units[i] != .doubleQuote {
            if units[i] == .backslash {
                i = min(i + 2, units.count)
            } else if units[i] == .dollar, let end = variableEnd(at: i) {
                if pieceStart < i { tokens.append(Token(kind: .string, range: pieceStart..<i)) }
                tokens.append(Token(kind: .variable, range: i..<end))
                i = end
                pieceStart = i
            } else {
                i += 1
            }
        }
        i = min(i + 1, units.count)
        if pieceStart < i { tokens.append(Token(kind: .string, range: pieceStart..<i)) }
    }

    /// The end of a `$name`, `${…}`, `$(…)` or `$?`-style variable at `index`, or nil for a lone `$`.
    private func variableEnd(at index: Int) -> Int? {
        let next = index + 1
        guard next < units.count else { return nil }
        let c = units[next]
        if c == .openBrace || c == .openParen {
            let close: UInt16 = c == .openBrace ? .closeBrace : .closeParen
            var depth = 0
            var j = next
            while j < units.count {
                if units[j] == c { depth += 1 }
                if units[j] == close {
                    depth -= 1
                    if depth == 0 { return j + 1 }
                }
                j += 1
            }
            return units.count
        }
        if c.isNameChar {
            var j = next
            while j < units.count, units[j].isNameChar { j += 1 }
            return j
        }
        if "?#$!@*-".utf16.contains(c) { return next + 1 }
        return nil
    }
}

private extension UInt16 {
    static let space = UInt16(32), tab = UInt16(9), newline = UInt16(10), carriageReturn = UInt16(13)
    static let hash = UInt16(35), dollar = UInt16(36), singleQuote = UInt16(39), doubleQuote = UInt16(34)
    static let backslash = UInt16(92), equals = UInt16(61), minus = UInt16(45)
    static let greater = UInt16(62), less = UInt16(60), pipe = UInt16(124), amp = UInt16(38), semicolon = UInt16(59)
    static let openParen = UInt16(40), closeParen = UInt16(41), openBrace = UInt16(123), closeBrace = UInt16(125)

    var isDigit: Bool { self >= 48 && self <= 57 }
    var isNameStart: Bool { (self >= 65 && self <= 90) || (self >= 97 && self <= 122) || self == 95 }
    var isNameChar: Bool { isNameStart || isDigit }
    var endsWord: Bool {
        self == .space || self == .tab || self == .newline || self == .carriageReturn || self == .pipe
            || self == .amp || self == .semicolon || self == .openParen || self == .closeParen
            || self == .greater || self == .less
    }
}
