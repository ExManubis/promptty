import Foundation

// Opening a tab from the phone: `places` lists where (the folders used most, the ssh hosts, the
// saved commands); `new-tab` opens it (a control command: `cwd`, its command as arguments, `label`),
// answering with the new pane's id, which the phone shows live and takes control of.

extension RemoteProtocol.Method {
    /// Where a tab can open (`RemotePlaces`).
    public static let places = "places"
}

public struct RemotePlaces: Codable, Equatable, Sendable {
    public struct Saved: Codable, Equatable, Sendable {
        public var name: String
        public var command: String

        public init(name: String, command: String) {
            self.name = name
            self.command = command
        }
    }

    /// The home folder.
    public var home: String
    /// The folders commands ran in, most used and most recent first (⌘J's).
    public var folders: [String]
    /// The hosts in `~/.ssh/config`.
    public var hosts: [String]
    /// Settings › Saved commands.
    public var commands: [Saved]

    public init(home: String, folders: [String], hosts: [String], commands: [Saved]) {
        self.home = home
        self.folders = folders
        self.hosts = hosts
        self.commands = commands
    }
}
