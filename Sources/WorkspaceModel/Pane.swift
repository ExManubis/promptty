import Foundation
import Observation

public struct PaneID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// One terminal inside a tab.
@MainActor
@Observable
public final class Pane {
    public let id: PaneID
    /// Title reported by the terminal (OSC 0/2 via Ghostty `set_title`).
    public var title: String
    /// Last working directory reported via OSC 7 (Ghostty `pwd`), or the launch directory.
    public var workingDirectory: String
    /// Run at the shell's first prompt (a pinned tab's command), then cleared.
    @ObservationIgnored public var startupCommand: String?
    /// The name of the file holding what the pane showed before the app quit (`ScrollbackArchive`),
    /// printed above its first prompt, then cleared.
    @ObservationIgnored public var restoredScrollback: String?

    public init(id: PaneID = PaneID(), title: String = "", workingDirectory: String, startupCommand: String? = nil) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.startupCommand = startupCommand
    }

    /// A title as a program set it, without the spinner it may animate in front ("✳ Claude
    /// Code", "⠋ Working"): the pane's title stays the same while the program works, so nothing
    /// that shows it redraws many times a second.
    public nonisolated static func terminalTitle(_ title: String) -> String {
        var rest = Substring(title)
        while let first = rest.unicodeScalars.first {
            let afterIt = rest.unicodeScalars.dropFirst()
            if isSpinnerFrame(first) {
                rest = Substring(afterIt)
            } else if "*·•".unicodeScalars.contains(first), let next = afterIt.first, next.properties.isWhitespace {
                // Only as a word of its own: Emacs's `*scratch*` is a name.
                rest = Substring(afterIt)
            } else if first.properties.isWhitespace, rest.count < title.count {
                rest = Substring(afterIt)
            } else {
                break
            }
        }
        return rest.isEmpty ? title : String(rest)
    }

    /// Braille dots (cli-spinners' "dots") and the asterisk-like dingbats ✢–✽ (Claude Code's).
    private nonisolated static func isSpinnerFrame(_ scalar: Unicode.Scalar) -> Bool {
        (0x2800...0x28FF).contains(scalar.value) || (0x2722...0x273D).contains(scalar.value)
    }
}
