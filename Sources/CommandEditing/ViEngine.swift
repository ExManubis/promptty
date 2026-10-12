import Foundation

/// The text being edited and the caret, as a UTF-16 offset (what `NSTextView` uses).
public struct EditBuffer: Equatable, Sendable {
    public var text: String
    public var cursor: Int

    public init(text: String, cursor: Int) {
        self.text = text
        self.cursor = cursor
    }
}

public enum ViMode: Equatable, Sendable { case insert, normal }

public enum ViKey: Equatable, Sendable {
    case char(Character)
    case escape
}

public enum ViResult: Equatable, Sendable {
    /// The engine changed the buffer or its own state.
    case handled
    /// Not a vi key here (insert mode): the text view edits natively.
    case unhandled
    /// `k` on the first line or `j` on the last: walk the command history.
    case historyOlder, historyNewer
    /// `u`: the text view undoes (it owns the undo stack).
    case undo
}

/// The unnamed register: what `d`, `c`, `x` and `y` keep for `p`/`P`.
public struct ViRegister: Equatable, Sendable {
    public var text: String
    /// Whole lines (`dd`, `yy`): pasted as lines above or below.
    public var linewise: Bool
}

/// Vi editing for the input bar. Insert mode is the text view's own editing; this engine handles
/// Escape there and every key in normal mode.
public struct ViEngine: Sendable {
    public private(set) var mode: ViMode = .insert
    public private(set) var register = ViRegister(text: "", linewise: false)

    private enum Pending: Equatable, Sendable {
        case replace
        case op(Character)
        case object(Character, around: Bool)
    }

    private var pending: Pending?
    private var count: Int?
    /// The count typed before an operator (`2dw`), multiplied with the motion's (`d2w`).
    private var operatorCount: Int?

    public init() {}

    public mutating func enterInsert() {
        mode = .insert
        resetPending()
    }

    public mutating func handle(_ key: ViKey, buffer: inout EditBuffer) -> ViResult {
        var t = TextModel(buffer)
        defer { buffer = t.buffer }
        switch (mode, key) {
        case (.insert, .escape):
            mode = .normal
            t.cursor = max(t.lineStart(t.cursor), t.cursor - 1)
            return .handled
        case (.insert, .char):
            return .unhandled
        case (.normal, .escape):
            resetPending()
            t.clampForNormal()
            return .handled
        case (.normal, .char(let c)):
            t.clampForNormal()
            let result = normal(c, &t)
            if mode == .normal { t.clampForNormal() }
            return result
        }
    }

    private mutating func resetPending() {
        pending = nil
        count = nil
        operatorCount = nil
    }

    // MARK: Normal mode

    private mutating func normal(_ c: Character, _ t: inout TextModel) -> ViResult {
        if pending == .replace {
            if t.cursor < t.lineEnd(t.cursor) { t.replace(t.cursor..<(t.cursor + 1), with: [c]) }
            resetPending()
            return .handled
        }
        if let digit = c.wholeNumberValue, digit > 0 || count != nil {
            count = (count ?? 0) * 10 + digit
            return .handled
        }
        if let p = pending, case .object(let op, let around) = p {
            defer { resetPending() }
            guard c == "w" || c == "W", let range = t.wordObject(at: t.cursor, big: c == "W", around: around) else { return .handled }
            apply(op, range: range, linewise: false, &t)
            return .handled
        }
        if let p = pending, case .op(let op) = p {
            return operatorKey(op, c, &t)
        }
        let n = count ?? 1
        defer { if pending == nil { count = nil } }
        switch c {
        case "i": mode = .insert
        case "a":
            if t.cursor < t.lineEnd(t.cursor) { t.cursor += 1 }
            mode = .insert
        case "I": t.cursor = t.firstNonBlank(t.cursor); mode = .insert
        case "A": t.cursor = t.lineEnd(t.cursor); mode = .insert
        case "o":
            let end = t.lineEnd(t.cursor)
            t.replace(end..<end, with: ["\n"])
            t.cursor = end + 1
            mode = .insert
        case "O":
            let start = t.lineStart(t.cursor)
            t.replace(start..<start, with: ["\n"])
            t.cursor = start
            mode = .insert
        case "x":
            let end = min(t.cursor + n, t.lineEnd(t.cursor))
            if t.cursor < end { yankAndDelete(t.cursor..<end, linewise: false, &t) }
        case "X":
            let start = max(t.lineStart(t.cursor), t.cursor - n)
            if start < t.cursor { yankAndDelete(start..<t.cursor, linewise: false, &t) }
        case "r": pending = .replace
        case "~":
            let end = min(t.cursor + n, t.lineEnd(t.cursor))
            let toggled = t.chars[t.cursor..<end].map { ch -> Character in
                let s = String(ch)
                return Character(s == s.uppercased() ? s.lowercased() : s.uppercased())
            }
            t.replace(t.cursor..<end, with: toggled)
            t.cursor = end
        case "D": apply("d", range: t.cursor..<t.lineEnd(t.cursor), linewise: false, &t)
        case "C": apply("c", range: t.cursor..<t.lineEnd(t.cursor), linewise: false, &t)
        case "s":
            let end = min(t.cursor + n, t.lineEnd(t.cursor))
            apply("c", range: t.cursor..<end, linewise: false, &t)
        case "S": linewise("c", lines: n, &t)
        case "d", "c", "y":
            operatorCount = count
            count = nil
            pending = .op(c)
        case "p", "P": paste(after: c == "p", &t)
        case "u": return .undo
        default:
            guard let m = motion(c, count: n, t) else { return .handled }
            switch m {
            case .to(let target, _): t.cursor = target
            case .history(let older): return older ? .historyOlder : .historyNewer
            }
        }
        return .handled
    }

    private mutating func operatorKey(_ op: Character, _ c: Character, _ t: inout TextModel) -> ViResult {
        if let digit = c.wholeNumberValue, digit > 0 || count != nil {
            count = (count ?? 0) * 10 + digit
            return .handled
        }
        defer { if case .object = pending {} else { resetPending() } }
        let n = (operatorCount ?? 1) * (count ?? 1)
        if c == op {
            linewise(op, lines: n, &t)
            return .handled
        }
        if c == "i" || c == "a" {
            pending = .object(op, around: c == "a")
            return .handled
        }
        // `cw` changes to the end of the word, like `ce` (vi's long-standing exception).
        let motionKey: Character = (op == "c" && (c == "w" || c == "W") && !t.isBlank(t.cursor)) ? (c == "w" ? "e" : "E") : c
        guard let m = motion(motionKey, count: n, t, forOperator: true), case .to(var target, let kind) = m else { return .handled }
        switch kind {
        case .linewise:
            let first = min(t.lineIndex(t.cursor), t.lineIndex(target))
            let last = max(t.lineIndex(t.cursor), t.lineIndex(target))
            t.cursor = t.startOfLine(number: first)
            linewise(op, lines: last - first + 1, &t)
        case .inclusive:
            let range = min(t.cursor, target)..<min(max(t.cursor, target) + 1, t.chars.count)
            apply(op, range: range, linewise: false, &t)
        case .exclusive:
            // `dw` on a line's last word stops at the line end instead of joining the next line.
            if (motionKey == "w" || motionKey == "W"), t.lineIndex(target) > t.lineIndex(t.cursor) {
                target = t.lineEnd(t.cursor)
            }
            let range = min(t.cursor, target)..<max(t.cursor, target)
            apply(op, range: range, linewise: false, &t)
        }
        return .handled
    }

    // MARK: Motions

    private enum MotionKind { case exclusive, inclusive, linewise }
    private enum Motion { case to(Int, MotionKind), history(older: Bool) }

    private func motion(_ c: Character, count n: Int, _ t: TextModel, forOperator: Bool = false) -> Motion? {
        var p = t.cursor
        switch c {
        case "h":
            return .to(max(t.lineStart(p), p - n), .exclusive)
        case "l":
            let limit = forOperator ? t.lineEnd(p) : max(t.lineStart(p), t.lineEnd(p) - 1)
            return .to(min(limit, p + n), .exclusive)
        case "0": return .to(t.lineStart(p), .exclusive)
        case "^": return .to(t.firstNonBlank(p), .exclusive)
        case "$":
            return .to(max(t.lineStart(p), t.lineEnd(p) - 1), .inclusive)
        case "w", "W":
            for _ in 0..<n { p = t.nextWordStart(p, big: c == "W") }
            return .to(forOperator ? p : min(p, max(0, t.chars.count - 1)), .exclusive)
        case "b", "B":
            for _ in 0..<n { p = t.previousWordStart(p, big: c == "B") }
            return .to(p, .exclusive)
        case "e", "E":
            for _ in 0..<n { p = t.wordEnd(p, big: c == "E") }
            return .to(p, .inclusive)
        case "j", "k":
            let line = t.lineIndex(p)
            let target = c == "j" ? line + n : line - n
            if target < 0 || target >= t.lineCount {
                if forOperator { return nil }
                return .history(older: c == "k")
            }
            let column = p - t.lineStart(p)
            let start = t.startOfLine(number: target)
            let end = t.lineEnd(start)
            return .to(min(start + column, max(start, end - 1)), .linewise)
        default:
            return nil
        }
    }

    // MARK: Edits

    private mutating func apply(_ op: Character, range: Range<Int>, linewise: Bool, _ t: inout TextModel) {
        switch op {
        case "y":
            register = ViRegister(text: String(t.chars[range]), linewise: linewise)
            t.cursor = range.lowerBound
        case "c":
            yankAndDelete(range, linewise: linewise, &t)
            mode = .insert
        default:
            yankAndDelete(range, linewise: linewise, &t)
        }
    }

    private mutating func yankAndDelete(_ range: Range<Int>, linewise: Bool, _ t: inout TextModel) {
        register = ViRegister(text: String(t.chars[range]), linewise: linewise)
        t.replace(range, with: [])
        t.cursor = range.lowerBound
    }

    /// `dd`, `cc`, `yy` (and `S`) on `lines` lines from the cursor's.
    private mutating func linewise(_ op: Character, lines: Int, _ t: inout TextModel) {
        let firstLine = t.lineIndex(t.cursor)
        let lastLine = min(t.lineCount - 1, firstLine + lines - 1)
        let start = t.startOfLine(number: firstLine)
        let end = t.lineEnd(t.startOfLine(number: lastLine))
        let text = String(t.chars[start..<end]) + "\n"
        switch op {
        case "y":
            register = ViRegister(text: text, linewise: true)
        case "c":
            register = ViRegister(text: text, linewise: true)
            t.replace(start..<end, with: [])
            t.cursor = start
            mode = .insert
        default:
            register = ViRegister(text: text, linewise: true)
            if end < t.chars.count {
                t.replace(start..<(end + 1), with: [])
                t.cursor = start
            } else if start > 0 {
                t.replace((start - 1)..<end, with: [])
                t.cursor = t.lineStart(start - 1)
            } else {
                t.replace(start..<end, with: [])
                t.cursor = 0
            }
        }
    }

    private mutating func paste(after: Bool, _ t: inout TextModel) {
        guard !register.text.isEmpty else { return }
        if register.linewise {
            let body = Array(register.text.hasSuffix("\n") ? String(register.text.dropLast()) : register.text)
            if after {
                let end = t.lineEnd(t.cursor)
                t.replace(end..<end, with: ["\n"] + body)
                t.cursor = end + 1
            } else {
                let start = t.lineStart(t.cursor)
                t.replace(start..<start, with: body + ["\n"])
                t.cursor = start
            }
        } else {
            let chars = Array(register.text)
            let at = after && t.cursor < t.lineEnd(t.cursor) ? t.cursor + 1 : t.cursor
            t.replace(at..<at, with: chars)
            t.cursor = at + chars.count - 1
        }
    }
}

/// The buffer as characters (grapheme clusters), so motions never split an emoji.
private struct TextModel {
    var chars: [Character]
    var cursor: Int

    init(_ buffer: EditBuffer) {
        chars = Array(buffer.text)
        var utf16 = 0
        var index = 0
        for ch in chars {
            if utf16 >= buffer.cursor { break }
            utf16 += ch.utf16.count
            index += 1
        }
        cursor = index
    }

    var buffer: EditBuffer {
        let text = String(chars)
        let offset = chars[..<min(cursor, chars.count)].reduce(0) { $0 + $1.utf16.count }
        return EditBuffer(text: text, cursor: offset)
    }

    mutating func replace(_ range: Range<Int>, with new: [Character]) {
        chars.replaceSubrange(range, with: new)
    }

    // MARK: Lines

    func lineStart(_ i: Int) -> Int {
        var j = min(i, chars.count)
        while j > 0, chars[j - 1] != "\n" { j -= 1 }
        return j
    }

    /// Exclusive: the index of the line's newline, or the end of the text.
    func lineEnd(_ i: Int) -> Int {
        var j = min(i, chars.count)
        while j < chars.count, chars[j] != "\n" { j += 1 }
        return j
    }

    func lineIndex(_ i: Int) -> Int { chars[..<min(i, chars.count)].filter { $0 == "\n" }.count }
    var lineCount: Int { chars.filter { $0 == "\n" }.count + 1 }

    func startOfLine(number n: Int) -> Int {
        guard n > 0 else { return 0 }
        var seen = 0
        for (i, ch) in chars.enumerated() where ch == "\n" {
            seen += 1
            if seen == n { return i + 1 }
        }
        return chars.count
    }

    func firstNonBlank(_ i: Int) -> Int {
        var j = lineStart(i)
        let end = lineEnd(i)
        while j < end, chars[j] == " " || chars[j] == "\t" { j += 1 }
        return j
    }

    /// Normal mode keeps the caret on a character: never past the line's last one.
    mutating func clampForNormal() {
        cursor = min(max(0, cursor), chars.count)
        let start = lineStart(cursor)
        let end = lineEnd(cursor)
        cursor = end > start ? min(cursor, end - 1) : start
    }

    // MARK: Words

    func isBlank(_ i: Int) -> Bool { i >= chars.count || chars[i].isWhitespace }

    /// 0 blank, 1 word characters, 2 other; for WORDs, 1 for anything non-blank.
    private func kind(_ i: Int, big: Bool) -> Int {
        guard i < chars.count else { return 0 }
        let ch = chars[i]
        if ch.isWhitespace { return 0 }
        if big { return 1 }
        return ch.isLetter || ch.isNumber || ch == "_" ? 1 : 2
    }

    func nextWordStart(_ i: Int, big: Bool) -> Int {
        var j = i
        let k = kind(j, big: big)
        if k != 0 { while j < chars.count, kind(j, big: big) == k { j += 1 } }
        while j < chars.count, kind(j, big: big) == 0 { j += 1 }
        return j
    }

    func previousWordStart(_ i: Int, big: Bool) -> Int {
        var j = i
        while j > 0, kind(j - 1, big: big) == 0 { j -= 1 }
        guard j > 0 else { return 0 }
        let k = kind(j - 1, big: big)
        while j > 0, kind(j - 1, big: big) == k { j -= 1 }
        return j
    }

    func wordEnd(_ i: Int, big: Bool) -> Int {
        var j = i + 1
        while j < chars.count, kind(j, big: big) == 0 { j += 1 }
        guard j < chars.count else { return max(0, chars.count - 1) }
        let k = kind(j, big: big)
        while j + 1 < chars.count, kind(j + 1, big: big) == k { j += 1 }
        return j
    }

    /// `iw`/`aw` (and the WORD forms): the run of same-kind characters under the caret, plus, for
    /// `aw`, the blanks after it (or before it when there are none after).
    func wordObject(at i: Int, big: Bool, around: Bool) -> Range<Int>? {
        guard i < chars.count, chars[i] != "\n" else { return nil }
        let k = kind(i, big: big)
        var start = i
        var end = i + 1
        while start > lineStart(i), kind(start - 1, big: big) == k { start -= 1 }
        while end < lineEnd(i), kind(end, big: big) == k { end += 1 }
        guard around, k != 0 else { return start..<end }
        var trailing = end
        while trailing < lineEnd(i), kind(trailing, big: big) == 0 { trailing += 1 }
        if trailing > end { return start..<trailing }
        var leading = start
        while leading > lineStart(i), kind(leading - 1, big: big) == 0 { leading -= 1 }
        return leading..<end
    }
}
