import Foundation

/// What a ⌘-clicked link points at, as something the system may open.
public enum LinkTarget {
    /// The URL to open for the text libghostty found, or nil for what must not be opened. Text with
    /// a scheme is a URL (the system decides whether it can open it). Anything else is a file path
    /// (`~` expanded, a relative one taken from `directory`), opened only if it exists and is not
    /// a program: an executable file or an application would be launched, not shown.
    public static func resolve(_ text: String, relativeTo directory: String? = nil) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let url: URL
        if let candidate = URL(string: text), let scheme = candidate.scheme, !scheme.isEmpty {
            url = candidate
        } else {
            var path = (text as NSString).expandingTildeInPath
            if !path.hasPrefix("/") {
                guard let directory, !directory.isEmpty else { return nil }
                path = (directory as NSString).appendingPathComponent(path)
            }
            url = URL(fileURLWithPath: (path as NSString).standardizingPath)
        }
        guard url.isFileURL else { return url }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return url.pathExtension.lowercased() == "app" ? nil : url
        }
        return FileManager.default.isExecutableFile(atPath: url.path) ? nil : url
    }
}
