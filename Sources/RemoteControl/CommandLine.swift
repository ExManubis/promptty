import Foundation

/// `promptty`'s arguments: `promptty [-p PANE] [--json] COMMAND [ARGS…] [--cwd DIR] [--enter] [--all] [-- COMMAND…]`.
/// Options may come before or after the command.
public enum ControlCommandLine {
    public static let commands: Set<String> = ["ls", "new-tab", "split", "send", "capture", "focus", "notify", "label"]

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
            case "-p", "--pane":
                guard let value = rest.popFirst() else { throw UsageError(message: "\(arg) needs a pane") }
                request.target = value
            case "--cwd", "-C":
                guard let value = rest.popFirst() else { throw UsageError(message: "\(arg) needs a folder") }
                request.options["cwd"] = value
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
        default: break
        }
        return .request(request)
    }

    public static let help = """
    promptty — control PrompTTY from its own terminals

    usage: promptty [-p PANE] [--json] COMMAND [ARGS…]

      ls                              windows, tabs and panes
      new-tab [--cwd DIR] [-- CMD…]   a new tab, running CMD
      split right|down [--cwd DIR] [-- CMD…]
                                      split this pane (or -p PANE)
      send TEXT… [--enter]            type into a pane; --enter runs it
      capture [--all]                 a pane's screen (--all: its scrollback too)
      focus -p PANE                   bring a pane forward
      notify TITLE [BODY]             post a notification for this pane
      label [NAME]                    label this pane (none: remove it)

    PANE is a pane's id, the end of it (4 characters or more), or its label.
    Exit status: 0 ok, 1 failed, 2 usage, 3 pane not found or ambiguous, 4 PrompTTY not reachable.
    """
}
