import Foundation
import AgentHooks

/// What `promptty` asks of the app: one JSON line on the control socket.
public struct ControlRequest: Codable, Equatable, Sendable {
    public var command: String
    /// The pane `promptty` runs in (`PROMPTTY_PANE_ID`); nil outside PrompTTY.
    public var caller: String?
    /// `-p`: the pane to act on, by id, id suffix or label; nil acts on the caller.
    public var target: String?
    public var arguments: [String]
    /// `--json`, `--enter`, `--all`, `--keep-open`, `--command-line`, `--markdown`.
    public var flags: Set<String>
    /// `--cwd DIR`, `--label NAME`, `--cmd ID`, `--timeout S`.
    public var options: [String: String]

    public init(command: String, caller: String? = nil, target: String? = nil, arguments: [String] = [],
                flags: Set<String> = [], options: [String: String] = [:]) {
        self.command = command; self.caller = caller; self.target = target; self.arguments = arguments
        self.flags = flags; self.options = options
    }

    public var wantsJSON: Bool { flags.contains("json") }
}

/// The app's answer: what to print and the exit status.
public struct ControlResponse: Codable, Equatable, Sendable, Error {
    public var status: Int32
    /// Printed to standard output (status 0) or standard error.
    public var text: String
    /// Printed instead of `text` with `--json`.
    public var json: String?

    public init(status: ControlStatus, text: String, json: String? = nil) {
        self.status = status.rawValue; self.text = text; self.json = json
    }

    /// A response with a status of its own: `wait` exits with the command's.
    public init(code: Int32, text: String, json: String? = nil) {
        self.status = code; self.text = text; self.json = json
    }

    public static func ok(_ text: String = "", json: String? = nil) -> ControlResponse { .init(status: .ok, text: text, json: json) }
    public static func failed(_ text: String) -> ControlResponse { .init(status: .failed, text: text) }
}

/// `promptty`'s exit statuses, as Rex's CLI has them.
public enum ControlStatus: Int32, Sendable {
    case ok = 0
    case failed = 1
    case usage = 2
    /// The pane named is not there, or more than one is.
    case target = 3
    /// The app is not running, or remote control is off.
    case unreachable = 4
    /// `wait` gave up before the command finished.
    case timedOut = 5
}

/// The variables every pane starts with for `promptty`.
public enum ControlEnvironment {
    public static let socketVariable = "PROMPTTY_CONTROL"
    /// The pane, shared with the agent hooks.
    public static let paneVariable = "PROMPTTY_PANE_ID"
    /// The pane as Rex names its panes ("blocks"): `block:` and its id.
    public static let blockVariable = "PROMPTTY_BLOCK"
    public static let blockPrefix = "block:"

    /// A pane's id as Rex writes a block's: `block:` and the id, lowercase.
    public static func blockID(pane: UUID) -> String { blockPrefix + pane.uuidString.lowercased() }

    /// The app's control socket as the app names it (`AppPaths.controlSocket`), for `promptty`
    /// run outside a pane, as from a launcher or a script: `control.sock` in the data folder.
    public static func defaultSocket(home: String = NSHomeDirectory(), temporaryDirectory: String = NSTemporaryDirectory()) -> String {
        let dataFolder = (home as NSString).appendingPathComponent("Library/Application Support/PrompTTY")
        return HookSocket.path(named: "control", dataFolder: dataFolder, temporaryDirectory: temporaryDirectory)
    }
}

extension JSONEncoder {
    /// Stable output for scripts: sorted keys, readable.
    public static var control: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
