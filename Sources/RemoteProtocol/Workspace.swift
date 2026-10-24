import Foundation

// What `subscribe` sends: the Mac's windows, projects, tabs and panes as its sidebar shows them,
// then an event each time that changes, and one when a command ends. Times are Unix seconds.

extension RemoteProtocol.Method {
    /// The workspace now (`RemoteWorkspace`), then `workspace` and `command.finished` events.
    public static let subscribe = "subscribe"
    /// No more events.
    public static let unsubscribe = "unsubscribe"
    /// A pane's recent commands (`BlocksParams` → `BlocksResult`); a command's output is `capture`
    /// with its id (`cmd`), as text or with `markdown`.
    public static let blocks = "blocks"
}

extension RemoteProtocol.Event {
    /// The workspace changed: its new `RemoteWorkspace`.
    public static let workspace = "workspace"
    /// A command ended in a pane (`CommandFinished`).
    public static let commandFinished = "command.finished"
}

extension RemoteProtocol {
    /// The events the Mac sends: notifications, which ask for no answer.
    public enum Event {}
}

public struct RemoteWorkspace: Codable, Equatable, Sendable {
    public var windows: [RemoteWindow]
    public var projects: [RemoteProject]

    public init(windows: [RemoteWindow], projects: [RemoteProject]) {
        self.windows = windows
        self.projects = projects
    }
}

public struct RemoteProject: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var folded: Bool

    public init(id: String, name: String, folded: Bool) {
        self.id = id
        self.name = name
        self.folded = folded
    }
}

public struct RemoteWindow: Codable, Equatable, Sendable {
    public var id: String
    /// The window in front on the Mac.
    public var key: Bool
    public var selectedTab: String?
    public var tabs: [RemoteTab]

    public init(id: String, key: Bool, selectedTab: String?, tabs: [RemoteTab]) {
        self.id = id
        self.key = key
        self.selectedTab = selectedTab
        self.tabs = tabs
    }
}

public struct RemoteTab: Codable, Equatable, Sendable {
    public var id: String
    /// As the Mac's sidebar titles its row ("zsh", or an agent's task).
    public var title: String
    /// The folder its row shows dimmed after the title ("~/api"); none for an agent's row.
    public var folder: String?
    /// Its project's id.
    public var project: String?
    public var pinned: Bool
    public var focusedPane: String
    public var panes: [RemotePane]

    public init(id: String, title: String, folder: String? = nil, project: String?, pinned: Bool, focusedPane: String, panes: [RemotePane]) {
        self.id = id
        self.title = title
        self.folder = folder
        self.project = project
        self.pinned = pinned
        self.focusedPane = focusedPane
        self.panes = panes
    }
}

public struct RemotePane: Codable, Equatable, Sendable {
    public var id: String
    public var label: String?
    public var title: String
    public var folder: String
    /// The program running in it, by its `ProgramCatalog` id ("claude", "neovim", …).
    public var program: String?
    public var state: RemotePaneState
    /// The exit code of the command that failed (`state` failed).
    public var exitCode: Int?
    /// While an agent works or waits: its tool and since when.
    public var agent: RemoteAgent?
    /// It printed while the user looked elsewhere.
    public var unseen: Bool
    /// The ports its programs listen on.
    public var ports: [Int]
    /// The host it is logged in to over ssh.
    public var remote: String?
    /// Its newest commands, newest last.
    public var commands: [RemoteCommand]

    public init(id: String, label: String? = nil, title: String, folder: String, program: String? = nil, state: RemotePaneState = .idle,
                exitCode: Int? = nil, agent: RemoteAgent? = nil, unseen: Bool = false, ports: [Int] = [], remote: String? = nil,
                commands: [RemoteCommand] = []) {
        self.id = id
        self.label = label
        self.title = title
        self.folder = folder
        self.program = program
        self.state = state
        self.exitCode = exitCode
        self.agent = agent
        self.unseen = unseen
        self.ports = ports
        self.remote = remote
        self.commands = commands
    }
}

/// What a pane shows, as the Mac's activity dot does.
public enum RemotePaneState: String, Codable, Sendable {
    case idle, running, working, finished, failed, attention, permission
}

public struct RemoteAgent: Codable, Equatable, Sendable {
    /// The tool it runs or asks to run ("Bash").
    public var tool: String?
    /// When its state last changed.
    public var since: Double?

    public init(tool: String?, since: Double?) {
        self.tool = tool
        self.since = since
    }
}

public struct RemoteCommand: Codable, Equatable, Sendable {
    /// `cmd:` and a UUID: `capture`'s `cmd`.
    public var id: String
    public var command: String
    public var running: Bool
    public var exitCode: Int?
    public var started: Double
    public var finished: Double?

    public init(id: String, command: String, running: Bool, exitCode: Int?, started: Double, finished: Double?) {
        self.id = id
        self.command = command
        self.running = running
        self.exitCode = exitCode
        self.started = started
        self.finished = finished
    }
}

/// `command.finished`'s params.
public struct CommandFinished: Codable, Equatable, Sendable {
    public var pane: String
    public var tab: String
    public var command: RemoteCommand

    public init(pane: String, tab: String, command: RemoteCommand) {
        self.pane = pane
        self.tab = tab
        self.command = command
    }
}

public struct BlocksParams: Codable, Equatable, Sendable {
    /// The pane, by id, id suffix or label, as `-p` names one.
    public var pane: String
    /// At most this many, the newest; 20 when not given.
    public var limit: Int?

    public init(pane: String, limit: Int? = nil) {
        self.pane = pane
        self.limit = limit
    }
}

public struct BlocksResult: Codable, Equatable, Sendable {
    public var pane: String
    public var commands: [RemoteCommand]

    public init(pane: String, commands: [RemoteCommand]) {
        self.pane = pane
        self.commands = commands
    }
}
