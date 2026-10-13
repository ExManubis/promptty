import Foundation
import UniformTypeIdentifiers

/// What to do with a ⌘-clicked link.
public enum LinkDecision: Equatable, Sendable {
    /// Hand to the system: its default app, or Finder for a folder.
    case open(URL)
    /// A file for the default text editor.
    case openAsText(URL)
    /// Ask first: the system would start another app on it.
    case confirm(URL)
    /// Show in Finder instead of opening.
    case reveal(URL)
    case refuse
}

/// What a ⌘-clicked link points at, and whether it may be opened. Nothing is ever run: a program,
/// an application or a launchable document is refused (or shown, for a script, in a text editor).
public enum LinkTarget {
    private static let openSchemes: Set<String> = ["http", "https", "mailto", "ftp"]
    private static let refusedSchemes: Set<String> = ["javascript", "data"]
    /// Text starting with one of these (and a colon) is a URL even without `//`.
    private static let knownSchemes = openSchemes.union(refusedSchemes).union(["file"])
    /// Files the system launches or installs when opened.
    private static let launchable: Set<String> = [
        "app", "command", "tool", "terminal", "workflow", "scpt", "scptd", "prefpane", "saver", "action",
        "webloc", "fileloc", "url", "jar", "dmg", "pkg", "mpkg", "sh", "zsh", "bash", "csh", "ksh", "fish",
        "appex", "xpc", "kext", "plugin", "bundle",
    ]
    private static let launchableTypes: [UTType] = [
        .executable, .script, .shellScript, .application, .applicationBundle, .applicationExtension,
        .unixExecutable, .diskImage, .package, .bundle, .framework, .internetShortcut,
        UTType("com.apple.installer-package"), UTType("com.apple.application"), UTType("com.apple.automator-workflow"),
        UTType("com.apple.terminal.command"),
    ].compactMap { $0 }
    private static let openableTypes: [UTType] = [.text, .sourceCode, .image, .pdf, .audio, .movie]
    private static let scriptExtensions: Set<String> = ["command", "tool", "sh", "zsh", "bash", "csh", "ksh", "fish"]

    public static func decide(_ text: String, kind: OpenURLKind = .unknown, relativeTo directory: String? = nil) -> LinkDecision {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .refuse }
        // `path:line:col` first: a path that exists wins over reading the text as a URL.
        if let path = existingPath(text, relativeTo: directory) { return decide(file: path, kind: kind) }
        let lower = text.lowercased()
        let scheme = lower.prefix { $0 != ":" && $0 != "/" }
        let isURL = lower.contains("://") || knownSchemes.contains(where: { lower.hasPrefix($0 + ":") })
        guard isURL, scheme.count < lower.count, let url = URL(string: text), let urlScheme = url.scheme?.lowercased() else { return .refuse }
        if urlScheme == "file" { return url.path.isEmpty ? .refuse : decide(file: URL(fileURLWithPath: url.path), kind: kind) }
        if refusedSchemes.contains(urlScheme) { return .refuse }
        return openSchemes.contains(urlScheme) ? .open(url) : .confirm(url)
    }

    /// The file the text names (`~` expanded, a relative one taken from `directory`, a trailing
    /// `:line` or `:line:col` dropped), if it exists.
    private static func existingPath(_ text: String, relativeTo directory: String?) -> URL? {
        var candidates = [text]
        if let range = text.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) { candidates.append(String(text[..<range.lowerBound])) }
        for candidate in candidates.reversed() where !candidate.isEmpty {
            if candidate.contains("://") { continue }
            var path = (candidate as NSString).expandingTildeInPath
            if !path.hasPrefix("/") {
                guard let directory, !directory.isEmpty else { continue }
                path = (directory as NSString).appendingPathComponent(path)
            }
            let url = URL(fileURLWithPath: (path as NSString).standardizingPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func decide(file url: URL, kind: OpenURLKind) -> LinkDecision {
        // Judge what a link leads to, not the link.
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path),
              let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isApplicationKey, .isPackageKey, .contentTypeKey])
        else { return .refuse }
        let ext = resolved.pathExtension.lowercased()
        let type = values.contentType
        let isProgram = values.isApplication == true || values.isPackage == true || launchable.contains(ext)
            || (type.map { t in launchableTypes.contains { t.conforms(to: $0) } } ?? false)
        if values.isDirectory == true { return isProgram ? .refuse : .open(resolved) }
        let executable = FileManager.default.isExecutableFile(atPath: resolved.path)
        if isProgram || executable {
            // A script may be read in a text editor, never run.
            let isScript = scriptExtensions.contains(ext) || (type?.conforms(to: .script) ?? false)
                || (executable && (type?.conforms(to: .text) ?? false))
            return kind == .text && isScript && values.isApplication != true && values.isPackage != true ? .openAsText(resolved) : .refuse
        }
        guard let type, openableTypes.contains(where: { type.conforms(to: $0) }) else { return .reveal(resolved) }
        if kind == .text, type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .openAsText(resolved) }
        return .open(resolved)
    }
}
