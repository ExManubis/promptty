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
        let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = custom.isEmpty ? title : custom
        let cleaned = Tab.sanitize(raw)
        return cleaned.isEmpty ? Tab.fallbackTitle : cleaned
    }

    public var abbreviatedDirectory: String {
        Tab.abbreviate(workingDirectory)
    }

    /// Removes C0/C1 controls and newlines, collapses whitespace, truncates.
    static func sanitize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(min(s.count, maxDisplayTitleLength))
        for scalar in s.unicodeScalars {
            if scalar.properties.generalCategory == .control { continue }
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { continue }
            out.unicodeScalars.append(scalar)
            if out.count >= maxDisplayTitleLength { break }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
