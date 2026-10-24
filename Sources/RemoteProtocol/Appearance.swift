import Foundation

extension RemoteProtocol.Method {
    /// The Mac's terminal config (`RemoteAppearance`), so a client draws a mirrored pane with the
    /// Mac's font and colors.
    public static let appearance = "appearance"
}

public struct RemoteAppearance: Codable, Equatable, Sendable {
    /// A Ghostty config, as the Mac writes `terminal.conf`, with the dark theme written out inline
    /// (its palette, background and foreground lines) instead of named: a client has no theme files.
    public var config: String

    public init(config: String) {
        self.config = config
    }
}
