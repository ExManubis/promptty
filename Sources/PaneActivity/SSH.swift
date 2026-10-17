import Foundation

/// Where an `ssh` (or `mosh`) in a pane is connected: its destination, from its arguments.
public enum SSHCommand {
    /// ssh's options that take a value (`-p 22`, `-i key`), per its manual.
    static let optionsWithValue = Set("BbcDEeFIiJLlmOoPpQRSWw")

    /// `user@host` or `host`; nil when no destination is given (`ssh -V`).
    public static func destination(arguments: [String]) -> String? {
        var user: String?
        var args = arguments.dropFirst()[...]
        while let arg = args.first {
            args = args.dropFirst()
            if arg == "--" { break }
            if arg.hasPrefix("--") { continue } // mosh's `--ssh=…`, `--port=…`
            if arg.hasPrefix("-"), arg.count > 1 {
                // Flags may be bundled (`-tA`); a value-taking one takes the rest, or the next word.
                let letters = Array(arg.dropFirst())
                for (i, letter) in letters.enumerated() where optionsWithValue.contains(letter) {
                    let value = i + 1 < letters.count ? String(letters[(i + 1)...]) : args.first.map { args = args.dropFirst(); return $0 }
                    if letter == "l" { user = value }
                    break
                }
                continue
            }
            return host(arg, user: user)
        }
        return args.first.map { host($0, user: user) }
    }

    private static func host(_ arg: String, user: String?) -> String {
        var dest = arg
        if dest.hasPrefix("ssh://") {
            dest.removeFirst("ssh://".count)
            // ssh://user@host:port
            if let colon = dest.lastIndex(of: ":"), !dest[dest.index(after: colon)...].isEmpty,
               dest[dest.index(after: colon)...].allSatisfy(\.isNumber) {
                dest = String(dest[..<colon])
            }
        }
        if let user, !dest.contains("@") { return "\(user)@\(dest)" }
        return dest
    }
}

/// The hosts named in an ssh config (`Host` lines without patterns), for quick connect.
public enum SSHConfig {
    /// `include`: the text of the files an `Include` line names (its argument, as written), in
    /// order; nothing for a file that cannot be read. Includes are followed to `depth` levels.
    public static func hosts(in text: String, include: (String) -> [String] = { _ in [] }, depth: Int = 4) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func scan(_ text: String, depth: Int) {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                let (keyword, value) = split(line)
                switch keyword {
                case "host":
                    for name in words(value) where isLiteral(name) && seen.insert(name).inserted {
                        out.append(name)
                    }
                case "include" where depth > 0:
                    for pattern in words(value) {
                        for included in include(pattern) { scan(included, depth: depth - 1) }
                    }
                default:
                    continue
                }
            }
        }
        scan(text, depth: depth)
        return out
    }

    /// A keyword and its value: `Host a b`, or `Host=a b`.
    private static func split(_ line: String) -> (String, String) {
        guard let end = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return (line.lowercased(), "") }
        let keyword = line[..<end].lowercased()
        var rest = line[end...].drop { $0 == " " || $0 == "\t" }
        if rest.first == "=" { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
        return (keyword, String(rest))
    }

    /// Whitespace-separated words, a quoted one kept whole.
    private static func words(_ value: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        for ch in value {
            if ch == "\"" { quoted.toggle(); continue }
            if (ch == " " || ch == "\t"), !quoted {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func isLiteral(_ name: String) -> Bool {
        !name.contains(where: { "*?!".contains($0) })
    }
}
