import Foundation

/// A line of a pane's screen, as styled runs. Live terminals (PTY-78) render the Mac's bytes with
/// libghostty; until then the demo's screens are written with a little markup: `{2:git}` is "git"
/// in palette color 2, `{b:recap:}` is bold.
struct TerminalLine: Equatable, Identifiable {
    struct Run: Equatable {
        var text: String
        /// A palette index 0–15; nil for the foreground.
        var color: Int?
        var bold = false
    }

    let id = UUID()
    var runs: [Run]

    init(_ markup: String) {
        runs = Self.parse(markup)
    }

    static func == (a: TerminalLine, b: TerminalLine) -> Bool { a.runs == b.runs }

    private static func parse(_ markup: String) -> [Run] {
        var runs: [Run] = []
        var rest = Substring(markup)
        while !rest.isEmpty {
            guard let open = rest.firstIndex(of: "{"),
                  let colon = rest[open...].firstIndex(of: ":"),
                  let close = rest[colon...].firstIndex(of: "}") else {
                runs.append(Run(text: String(rest)))
                break
            }
            if open > rest.startIndex { runs.append(Run(text: String(rest[..<open]))) }
            let style = rest[rest.index(after: open)..<colon]
            let text = String(rest[rest.index(after: colon)..<close])
            if style == "b" {
                runs.append(Run(text: text, bold: true))
            } else {
                runs.append(Run(text: text, color: Int(style)))
            }
            rest = rest[rest.index(after: close)...]
        }
        return runs
    }
}
