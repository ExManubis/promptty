import Foundation

/// Writing names into zsh command lines so the shell reads each back as exactly one word.
public enum ShellQuoting {
    /// zsh reads bytes, not grapheme clusters: each of these is checked as a lone scalar, also when
    /// it shares a cluster with a combining mark. `^` is a glob operator with `extendedglob`.
    private static let special = Set(" \t'\"\\$&;|()<>*?[]#~`!{}^=%".unicodeScalars)

    /// Makes a name safe to put in a command line. A name with control characters (a newline in a
    /// file name would end the command and start another) is written in zsh's `$'…'` form. A
    /// leading `~` is kept as typed unless `keepLeadingTilde` is false.
    public static func escape(_ s: String, keepLeadingTilde: Bool = true) -> String {
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            var out = "$'"
            for u in s.unicodeScalars {
                switch u {
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case "'", "\\": out += "\\" + String(u)
                default:
                    if u.value < 0x20 || u.value == 0x7F {
                        out += String(format: "\\x%02x", u.value)
                    } else {
                        out.unicodeScalars.append(u)
                    }
                }
            }
            return out + "'"
        }
        var out = String.UnicodeScalarView()
        for (i, u) in s.unicodeScalars.enumerated() {
            // A leading ~ is the home shorthand.
            if special.contains(u), !(u == "~" && i == 0 && keepLeadingTilde) { out.append("\\") }
            out.append(u)
        }
        return String(out)
    }

    /// The command that changes to `path`, written the way a person would type it: with `~` for
    /// the home folder.
    public static func cdCommand(to path: String, home: String) -> String {
        if path == home { return "cd ~" }
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(homePrefix) {
            return "cd ~/" + escape(String(path.dropFirst(homePrefix.count)), keepLeadingTilde: false)
        }
        return "cd " + escape(path)
    }

    /// A dropped file's path as a command-line word: relative inside the pane's folder, with `~`
    /// under the home folder, absolute elsewhere.
    public static func pathArgument(_ path: String, directory: String, home: String) -> String {
        if path == directory { return "." }
        let folder = directory.hasSuffix("/") ? directory : directory + "/"
        if path.hasPrefix(folder) {
            let relative = String(path.dropFirst(folder.count))
            // `-rf` would read as an option.
            return (relative.hasPrefix("-") ? "./" : "") + escape(relative, keepLeadingTilde: false)
        }
        if path == home { return "~" }
        let homeFolder = home.hasSuffix("/") ? home : home + "/"
        if path.hasPrefix(homeFolder) {
            return "~/" + escape(String(path.dropFirst(homeFolder.count)), keepLeadingTilde: false)
        }
        return escape(path)
    }
}
