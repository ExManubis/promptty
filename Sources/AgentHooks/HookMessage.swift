import Foundation

/// What an agent's hook reports: the events of Claude Code's hooks PrompTTY listens to, and Codex's
/// `notify`.
public enum HookEvent: String, CaseIterable, Sendable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case notification = "Notification"
    case stop = "Stop"
    case subagentStop = "SubagentStop"
    /// Codex's `notify` program, given the event as JSON in its last argument.
    case codexNotify = "codex-notify"
}

/// The part of a hook's input PrompTTY uses. Claude Code passes much more (the prompt, a tool's
/// input and output); the helper sends only these fields to the app.
public struct HookPayload: Equatable, Sendable {
    public var sessionID: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var hookEventName: String?
    public var toolName: String?
    /// A Notification's text: "Claude needs your permission to use Bash", "Claude is waiting for
    /// your input".
    public var message: String?
    /// Newer versions name a Notification's kind: `permission_prompt`, `idle_prompt`, …
    public var notificationType: String?
    /// SessionStart: `startup`, `resume`, `clear` or `compact`.
    public var source: String?
    /// Codex: `agent-turn-complete`.
    public var type: String?

    public init(sessionID: String? = nil, transcriptPath: String? = nil, cwd: String? = nil, hookEventName: String? = nil,
                toolName: String? = nil, message: String? = nil, notificationType: String? = nil, source: String? = nil,
                type: String? = nil) {
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.toolName = toolName
        self.message = message
        self.notificationType = notificationType
        self.source = source
        self.type = type
    }

    /// The input's keys, as the agents name them.
    static let keys = ["session_id", "transcript_path", "cwd", "hook_event_name", "tool_name", "message",
                       "notification_type", "source", "type"]

    init(_ object: [String: Any]) {
        func string(_ key: String) -> String? { object[key] as? String }
        self.init(sessionID: string("session_id"), transcriptPath: string("transcript_path"), cwd: string("cwd"),
                  hookEventName: string("hook_event_name"), toolName: string("tool_name"), message: string("message"),
                  notificationType: string("notification_type"), source: string("source"), type: string("type"))
    }

    /// What a Notification asks of the user.
    public enum NotificationKind: Equatable, Sendable {
        /// To allow a tool.
        case permission
        /// To write something: the agent waits for a prompt or an answer.
        case input
        /// Nothing (a sign-in went through).
        case none
    }

    public var notificationKind: NotificationKind {
        switch notificationType {
        case "permission_prompt": return .permission
        case "idle_prompt", "elicitation_dialog": return .input
        case "auth_success": return .none
        default:
            // Older versions only say it in words.
            return message?.range(of: "permission", options: .caseInsensitive) != nil ? .permission : .input
        }
    }
}

/// A message on PrompTTY's hook socket: one line of JSON, `{"pane": …, "event": …, "payload": {…}}`.
public struct HookMessage: Equatable, Sendable {
    /// The pane the agent runs in (`PROMPTTY_PANE_ID`).
    public let pane: UUID
    public let event: HookEvent
    public let payload: HookPayload

    public init(pane: UUID, event: HookEvent, payload: HookPayload) {
        self.pane = pane
        self.event = event
        self.payload = payload
    }

    /// A line read from the socket (without its newline); nil when it is not a message PrompTTY
    /// knows.
    public static func parse(_ line: Data) -> HookMessage? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let pane = (object["pane"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        let payload: HookPayload
        switch object["payload"] {
        case nil: payload = HookPayload()
        case let fields as [String: Any]: payload = HookPayload(fields)
        default: return nil
        }
        // A hook set up without the event's name still says it in its input.
        let name: String?
        switch object["event"] {
        case nil: name = payload.hookEventName
        case let given as String: name = given.isEmpty ? payload.hookEventName : given
        default: return nil
        }
        guard let event = name.flatMap(HookEvent.init(rawValue:)) else { return nil }
        return HookMessage(pane: pane, event: event, payload: payload)
    }

    /// The line the helper sends for a hook's input (JSON, as Claude Code writes it to the hook's
    /// standard input), ending in a newline. Only the fields in `HookPayload` are kept: the prompt
    /// and tools' input never leave the helper. Input that is not a JSON object sends the event
    /// alone.
    public static func line(pane: UUID, event: String, input: Data) -> Data? {
        let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        var payload: [String: String] = [:]
        for key in HookPayload.keys { if let value = object[key] as? String { payload[key] = value } }
        let message: [String: Any] = ["pane": pane.uuidString, "event": event, "payload": payload]
        // Compact JSON escapes newlines inside strings: the message is one line.
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

/// The variables every pane starts with, which tell the helper where to report and for which pane.
public enum HookEnvironment {
    public static let paneVariable = "PROMPTTY_PANE_ID"
    public static let socketVariable = "PROMPTTY_SOCKET"

    public static func variables(pane: UUID, socket: String) -> [String: String] {
        [paneVariable: pane.uuidString, socketVariable: socket]
    }
}

/// Where the app listens for hooks.
public enum HookSocket {
    /// A Unix socket's path fits in `sun_path`: 104 bytes with the terminating NUL.
    public static let maxPathBytes = 103

    /// `hooks.sock` in the app's data folder; when that path is too long for a socket, a short one
    /// in the user's temporary folder named by a hash of the data folder (so each data folder, as a
    /// debug run's, still has its own), or failing that in `/tmp/promptty-<uid>/`, a folder only
    /// the user may enter (`HookListener` makes and checks it).
    public static func path(dataFolder: String, temporaryDirectory: String, userID: UInt32 = getuid()) -> String {
        path(named: "hooks", dataFolder: dataFolder, temporaryDirectory: temporaryDirectory, userID: userID)
    }

    /// `<name>.sock` in the data folder, falling back as `path(dataFolder:…)` does; the hook
    /// socket's name keeps its old fallbacks.
    public static func path(named name: String, dataFolder: String, temporaryDirectory: String, userID: UInt32 = getuid()) -> String {
        let preferred = (dataFolder as NSString).appendingPathComponent("\(name).sock")
        if preferred.utf8.count <= maxPathBytes { return preferred }
        let tag = name == "hooks" ? "" : "\(name)-"
        let file = "promptty-\(tag)\(hash(dataFolder)).sock"
        let temporary = (temporaryDirectory as NSString).appendingPathComponent(file)
        if temporary.utf8.count <= maxPathBytes { return temporary }
        return sharedFolder(userID: userID) + "/\(tag)\(hash(dataFolder)).sock"
    }

    /// The last resort's folder, in the world-writable `/tmp`.
    public static func sharedFolder(userID: UInt32 = getuid()) -> String { "/tmp/promptty-\(userID)" }

    /// FNV-1a, 64 bits, in hex: stable from run to run, unlike `hashValue`.
    static func hash(_ string: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100_0000_01b3
        }
        return String(h, radix: 16)
    }
}
