import Foundation

/// `promptty`'s arguments: `promptty [-p|-b PANE] [--json] COMMAND [ARGS…] [--cwd DIR] [--label NAME] [--keep-open]
/// [--enter] [--all] [-c CMD] [--timeout S] [--command-line|--markdown] [-- COMMAND…]`. Options may come before or
/// after the command. `-b`/`--block` is Rex's name for a pane.
public enum ControlCommandLine {
    public static let commands: Set<String> = ["ls", "new-tab", "split", "send", "capture", "wait", "focus", "close", "notify", "label"]

    public enum Parsed: Equatable, Sendable {
        case request(ControlRequest)
        case help
        case version
    }

    public struct UsageError: Error, Equatable, Sendable {
        public let message: String
    }

    public static func parse(_ arguments: [String], caller: String?) throws(UsageError) -> Parsed {
        var request = ControlRequest(command: "", caller: caller)
        var rest = arguments[...]
        var positional: [String] = []
        while let arg = rest.popFirst() {
            switch arg {
            case "-h", "--help", "help": return .help
            case "-v", "--version", "version": return .version
            case "--json": request.flags.insert("json")
            case "--enter", "-e": request.flags.insert("enter")
            case "--all", "-a": request.flags.insert("all")
            case "-p", "--pane", "-b", "--block":
                guard let value = rest.popFirst() else { throw UsageError(message: "\(arg) needs a pane") }
                request.target = value
            case "--cwd", "-C":
                guard let value = rest.popFirst() else { throw UsageError(message: "\(arg) needs a folder") }
                request.options["cwd"] = value
            case "--label", "-l":
                guard let value = rest.popFirst() else { throw UsageError(message: "\(arg) needs a name") }
                request.options["label"] = value
            case "--keep-open": request.flags.insert("keep-open")
            case "--cmd", "-c":
                guard let value = rest.popFirst() else { throw UsageError(message: "\(arg) needs a command id") }
                request.options["cmd"] = value
            case "--timeout", "-t":
                guard let value = rest.popFirst(), let seconds = Double(value), seconds > 0 else {
                    throw UsageError(message: "\(arg) needs a number of seconds")
                }
                request.options["timeout"] = String(seconds)
            case "--command-line": request.flags.insert("command-line")
            case "--markdown": request.flags.insert("markdown")
            case "--":
                positional += rest
                rest = []
            default:
                if arg.hasPrefix("-"), arg.count > 1, request.command.isEmpty || !["send", "notify"].contains(request.command) {
                    throw UsageError(message: "unknown option \(arg)")
                }
                if request.command.isEmpty { request.command = arg } else { positional.append(arg) }
            }
        }
        guard !request.command.isEmpty else { return .help }
        guard commands.contains(request.command) else { throw UsageError(message: "unknown command \(request.command)") }
        request.arguments = positional
        switch request.command {
        case "split":
            guard let direction = positional.first, ["right", "down"].contains(direction) else {
                throw UsageError(message: "split right|down [-- command…]")
            }
        case "send":
            guard !positional.isEmpty || request.flags.contains("enter") else { throw UsageError(message: "send TEXT… [--enter]") }
        case "notify", "label":
            guard !positional.isEmpty || request.command == "label" else { throw UsageError(message: "notify TITLE [BODY]") }
        case "focus":
            guard request.target != nil else { throw UsageError(message: "focus -p PANE") }
        case "close":
            // Named, never implied: closing the caller's own pane would end the program asking.
            guard request.target != nil else { throw UsageError(message: "close -b PANE") }
        case "wait":
            // Never the caller's own pane: its command is the one running `promptty`.
            guard request.options["cmd"] != nil || request.target != nil else {
                throw UsageError(message: "wait -b PANE | -c CMD [--timeout S]")
            }
        default: break
        }
        return .request(request)
    }

    /// How long the client waits for an answer: a `wait` as long as its timeout allows.
    public static func replyTimeout(for request: ControlRequest) -> TimeInterval {
        guard request.command == "wait" else { return 15 }
        return request.options["timeout"].flatMap(Double.init).map { $0 + 5 } ?? 7 * 24 * 3600
    }

    public static let help = """
    promptty — control PrompTTY from its own terminals (agents: see the workflow below)

    usage: promptty [-p PANE] [--json] COMMAND [ARGS…]

      ls                              windows, tabs and panes (--json: each pane's recent commands too)
      new-tab [--cwd DIR] [--label NAME] [-- CMD…]
                                      a new tab, running CMD
      split right|down [--cwd DIR] [--label NAME] [-- CMD…]
                                      split this pane (or -p PANE), running CMD
      send TEXT… [--enter]            type into a pane; --enter runs it
      capture [--all]                 a pane's screen (--all: its scrollback too)
      capture -c CMD [--command-line|--markdown]
                                      one command's output (or its command line, or both as Markdown)
      wait -p PANE | -c CMD [--timeout S]
                                      wait for the pane's command (or that command) to end; exits with its status
      focus -p PANE                   bring a pane forward
      close -p PANE                   close a pane, ending what runs in it (its tab, if it is the last)
      notify TITLE [BODY]             post a notification for this pane
      label [NAME]                    label this pane (none: remove it)

    PANE is a pane's id (block:… as Rex writes it, or without block:), the end of it (4 characters or
    more), or its label. -b/--block is the same as -p, as in Rex; a pane's own id is in $PROMPTTY_BLOCK.
    CMD is a command's id (cmd:…, or the end of it): every command run from a pane's input bar or by
    promptty has one. --json prints JSON: new-tab, split and send --enter give {"block", "pane", "cmd"}.
    --keep-open is accepted for Rex's scripts: a pane always stays open when its command ends.

    An agent running in PrompTTY can work in a pane beside it:
      promptty split right --label tests --json -- make test   # {"block": "block:…", "cmd": "cmd:…", …}
      promptty wait -b tests --timeout 600; echo "exit $?"
      promptty capture -c <cmd>                                 # that command's output only
      promptty send -b tests --enter --json make lint           # another command, another cmd id
      promptty close -b tests                                   # done with it

    Exit status: 0 ok, 1 failed, 2 usage, 3 pane or command not found or ambiguous, 4 PrompTTY not
    reachable, 5 wait timed out; `wait` otherwise exits with the command's own status.
    """
}
