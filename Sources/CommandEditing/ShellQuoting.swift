import Foundation

/// Writing names into zsh command lines so the shell reads each back as exactly one word.
public enum ShellQuoting {
    private static let special = Set(" \t'\"\\$&;|()<>*?[]#~`!{}")

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
        var out = ""
        for (i, ch) in s.enumerated() {
            // A leading ~ is the home shorthand.
            if special.contains(ch), !(ch == "~" && i == 0 && keepLeadingTilde) { out.append("\\") }
            out.append(ch)
        }
        return out
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
}
