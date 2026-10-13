import Foundation

/// PrompTTY's hooks in Claude Code's settings (`~/.claude/settings.json`): one command hook per
/// event, `'<helper>' <Event>`, under `"hooks"`. PrompTTY's entries are told apart by their
/// command (the helper, `…/promptty-hook`, wherever the app is), so installing again changes
/// nothing, an older copy's entries are replaced, and removing leaves every other hook and setting
/// as it was.
public enum ClaudeHookSettings {
    /// The events PrompTTY installs hooks for.
    public static let events: [HookEvent] = [.sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse,
                                             .notification, .stop, .subagentStop]

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The file is not JSON, or not an object, or its hooks are not in the shape Claude Code
        /// reads: PrompTTY leaves it alone.
        case unreadable

        public var description: String {
            "The settings file is not in a form PrompTTY can safely change; fix or move it first."
        }
    }

    /// The command for one event, the helper's path in single quotes (it may hold spaces).
    public static func command(helper: String, event: HookEvent) -> String {
        "'" + helper.replacingOccurrences(of: "'", with: #"'\''"#) + "' " + event.rawValue
    }

    /// Whether a hook's command runs a PrompTTY helper: a path ending in `/promptty-hook` (quoted or
    /// not), then the end or a space.
    public static func isOurs(_ command: String) -> Bool {
        var rest = Substring(command)
        while let found = rest.range(of: "/promptty-hook") {
            let after = rest[found.upperBound...]
            if after.isEmpty || after.first == " " || after.first == "'" || after.first == "\"" { return true }
            rest = after
        }
        return false
    }

    // MARK: Merging

    /// The settings with PrompTTY's hooks in them: any older ones taken out, then one group per
    /// event appended after the user's own.
    public static func installing(helper: String, into data: Data?) throws -> Data {
        var settings = try parse(data)
        var hooks = try hooksObject(of: settings) ?? [:]
        _ = try strip(&hooks)
        for event in events {
            var groups = hooks[event.rawValue] as? [Any] ?? []
            groups.append(["matcher": "", "hooks": [["type": "command", "command": command(helper: helper, event: event)]]] as [String: Any])
            hooks[event.rawValue] = groups
        }
        settings["hooks"] = hooks
        return try serialize(settings)
    }

    /// The settings without PrompTTY's hooks; groups, events and the `hooks` object that held only
    /// those go too. Settings with none come back as they were.
    public static func removing(from data: Data?) throws -> Data {
        var settings = try parse(data)
        guard var hooks = try hooksObject(of: settings), try strip(&hooks) else { return data ?? Data() }
        if hooks.isEmpty { settings["hooks"] = nil } else { settings["hooks"] = hooks }
        return try serialize(settings)
    }

    /// Whether every event has this helper's hook.
    public static func isInstalled(helper: String, in data: Data?) throws -> Bool {
        guard let hooks = try hooksObject(of: parse(data)) else { return false }
        return events.allSatisfy { event in
            commands(in: hooks[event.rawValue]).contains(command(helper: helper, event: event))
        }
    }

    private static func commands(in groups: Any?) -> [String] {
        (groups as? [Any] ?? []).flatMap { group in
            ((group as? [String: Any])?["hooks"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    /// Takes PrompTTY's hooks out of every event; returns whether there were any.
    private static func strip(_ hooks: inout [String: Any]) throws -> Bool {
        var removed = false
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { throw Failure.unreadable }
            var kept: [Any] = []
            var touched = false
            for group in groups {
                guard var object = group as? [String: Any], let entries = object["hooks"] as? [Any] else {
                    kept.append(group)
                    continue
                }
                let others = entries.filter { entry in
                    guard let command = (entry as? [String: Any])?["command"] as? String else { return true }
                    return !isOurs(command)
                }
                if others.count == entries.count {
                    kept.append(group)
                    continue
                }
                touched = true
                // A group of PrompTTY's alone goes; one shared with the user's hooks keeps theirs.
                if !others.isEmpty {
                    object["hooks"] = others
                    kept.append(object)
                }
            }
            guard touched else { continue }
            removed = true
            hooks[event] = kept.isEmpty ? nil : kept
        }
        return removed
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.unreadable }
        return object
    }

    private static func hooksObject(of settings: [String: Any]) throws -> [String: Any]? {
        guard let value = settings["hooks"] else { return nil }
        guard let hooks = value as? [String: Any] else { throw Failure.unreadable }
        return hooks
    }

    /// Sorted keys: the same settings always read the same (JSONSerialization keeps no order).
    private static func serialize(_ settings: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(UInt8(ascii: "\n"))
        return data
    }

    // MARK: Files

    public enum Outcome: Equatable, Sendable {
        case changed
        /// Already so: the file was not written.
        case unchanged
    }

    public enum Status: Equatable, Sendable {
        case installed
        /// Hooks of a PrompTTY elsewhere (an older copy, a build): installing replaces them.
        case otherCopy
        case notInstalled
        case unreadable
    }

    /// Merges PrompTTY's hooks into the settings file, creating it (and its folder) if missing.
    /// An existing file is copied to `<name>.bak` first and keeps its permissions; a symlink
    /// (dotfiles) is written through. A file that is not valid settings is not touched.
    public static func install(helper: String, in file: URL) throws -> Outcome {
        try rewrite(file) { try installing(helper: helper, into: $0) }
    }

    /// Takes PrompTTY's hooks out of the settings file, with a backup as for `install`.
    public static func remove(in file: URL) throws -> Outcome {
        try rewrite(file) { try removing(from: $0) }
    }

    public static func status(helper: String, in file: URL) -> Status {
        let data = try? Data(contentsOf: file)
        do {
            if try isInstalled(helper: helper, in: data) { return .installed }
            return try commands(in: hooksObject(of: parse(data))?.values.flatMap { $0 as? [Any] ?? [] }).contains(where: isOurs)
                ? .otherCopy : .notInstalled
        } catch {
            return .unreadable
        }
    }

    private static func rewrite(_ file: URL, _ change: (Data?) throws -> Data) throws -> Outcome {
        let fm = FileManager.default
        let target = file.resolvingSymlinksInPath()
        let existing = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
        let updated = try change(existing)
        // The same settings, however the file was laid out, are left as they are.
        guard try NSDictionary(dictionary: parse(updated)) != NSDictionary(dictionary: parse(existing)) else { return .unchanged }
        guard let existing else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: target, options: .atomic)
            return .changed
        }
        let permissions = try fm.attributesOfItem(atPath: target.path)[.posixPermissions]
        let backup = target.appendingPathExtension("bak")
        try existing.write(to: backup, options: .atomic)
        // The settings may hold keys (`env`): the backup and the new file are as private as the old.
        if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: backup.path) }
        try updated.write(to: target, options: .atomic)
        if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
        return .changed
    }
}
