import Foundation

/// What panes showed when the app quit, kept beside the session so restored tabs open with their
/// output above a fresh prompt. One file per pane, named in the session file; the shell
/// integration prints it once and deletes it.
public struct ScrollbackArchive: Sendable {
    /// Lines kept per pane: enough to see what happened, small enough to print at once.
    public static let maxLines = 2000

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    /// The text to keep from a pane: its last `maxLines` lines without the trailing blank ones (the
    /// empty prompt), then a dim line saying when it was saved. Nil when there is nothing to keep.
    public static func archived(_ text: String, savedAt date: Date, maxLines: Int = maxLines) -> String? {
        // From the end back, so a long text is not split whole for its last lines.
        var lines: [Substring] = []
        var end = text.endIndex
        while lines.count < maxLines {
            let newline = text.utf8[..<end].lastIndex(of: UInt8(ascii: "\n"))
            let start = newline.map { text.utf8.index(after: $0) } ?? text.startIndex
            var line = text[start..<end]
            if line.hasSuffix("\r") { line = line.dropLast() }
            if !lines.isEmpty || !Self.isBlank(line) { lines.append(line) }
            guard let newline else { break }
            end = newline
        }
        guard !lines.isEmpty else { return nil }
        lines.reverse()
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Reset the colors the output may leave set, then dim.
        let marker = "\u{1B}[0m\u{1B}[2m── restored · saved \(formatter.string(from: date)) ──\u{1B}[0m"
        return lines.joined(separator: "\r\n") + "\r\n\u{1B}[0m\r\n" + marker + "\r\n"
    }

    /// Writes the archives and removes every other file in the folder (earlier quits') but those
    /// in `keeping` (restored panes never shown, whose shells have not printed theirs yet). `texts`:
    /// a name for each pane's text. Returns the names written.
    @discardableResult
    public func replace(with texts: [String: String], keeping: Set<String> = []) -> Set<String> {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var written = Set<String>()
        for (name, text) in texts {
            do {
                try Data(text.utf8).write(to: url(for: name), options: .atomic)
                written.insert(name)
            } catch {
                continue
            }
        }
        for stale in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !written.contains(stale) && !keeping.contains(stale) {
            try? fm.removeItem(at: url(for: stale))
        }
        return written
    }

    /// Removes every archive (restoring scrollback was turned off).
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func isBlank(_ line: Substring) -> Bool {
        // SGR-only lines (a color reset) count as blank too.
        var rest = line[...]
        while let esc = rest.firstIndex(of: "\u{1B}") {
            guard rest[..<esc].allSatisfy(\.isWhitespace) else { return false }
            guard let end = rest[esc...].firstIndex(where: { $0.isLetter }) else { return false }
            rest = rest[rest.index(after: end)...]
        }
        return rest.allSatisfy(\.isWhitespace)
    }
}
