import Foundation
import Observation

public struct TabID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

@MainActor
@Observable
public final class Tab {
    public static let maxDisplayTitleLength = 80
    public static let fallbackTitle = "Terminal"

    public let id: TabID
    /// Title reported by the terminal (OSC 0/2 via Ghostty `set_title`).
    public var title: String
    /// User rename; blank means none.
    public var customTitle: String?
    /// Last working directory reported via OSC 7 (Ghostty `pwd`), or the launch directory.
    public var workingDirectory: String

    public init(id: TabID = TabID(), title: String, customTitle: String? = nil, workingDirectory: String) {
        self.id = id
        self.title = title
        self.customTitle = customTitle
        self.workingDirectory = workingDirectory
    }

    public var displayTitle: String {
        let custom = Tab.sanitize(customTitle ?? "")
        if !custom.isEmpty { return custom }
        let shell = Tab.sanitize(title)
        return shell.isEmpty ? Tab.fallbackTitle : shell
    }

    public var abbreviatedDirectory: String {
        Tab.abbreviate(workingDirectory)
    }

    /// Makes a terminal- or user-supplied title safe to show on one line:
    /// drops line/paragraph separators, control and format scalars (escapes,
    /// bidi overrides, zero-width characters); maps any other whitespace
    /// (tabs, newlines, Unicode spaces) to a single ASCII space, collapsing runs
    /// and trimming both ends; then truncates to `maxDisplayTitleLength` characters.
    static func sanitize(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for scalar in s.unicodeScalars {
            let category = scalar.properties.generalCategory
            if category == .lineSeparator || category == .paragraphSeparator { continue }
            if scalar.properties.isWhitespace || category == .spaceSeparator {
                pendingSpace = !out.isEmpty
                continue
            }
            if category == .control || category == .format { continue }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.unicodeScalars.append(scalar)
        }
        guard out.count > maxDisplayTitleLength else { return out }
        return String(out.prefix(maxDisplayTitleLength))
            .trimmingCharacters(in: .whitespaces)
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
