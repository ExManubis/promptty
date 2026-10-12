import Foundation
import Observation

/// Reads and writes `settings.json`.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public enum LoadResult: Equatable, Sendable {
        /// No file yet (first launch).
        case missing
        case loaded(Settings)
        /// The file was unusable; it was moved to `<name>.bak` and defaults apply.
        case recovered
    }

    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            guard settings.version <= Settings.currentVersion else { throw CocoaError(.coderInvalidValue) }
            return .loaded(settings)
        } catch {
            moveAside()
            return .recovered
        }
    }

    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }

    private func moveAside() {
        let bak = URL(fileURLWithPath: url.path + ".bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.moveItem(at: url, to: bak)
    }
}

/// The live settings the UI binds to. Assignments are normalized; `onChange` fires only for real changes.
@MainActor
@Observable
public final class SettingsModel {
    public var settings: Settings {
        didSet {
            let normalized = settings.normalized()
            if normalized != settings {
                settings = normalized
                return
            }
            if settings != oldValue { onChange?(settings) }
        }
    }

    @ObservationIgnored public var onChange: ((Settings) -> Void)?

    public init(settings: Settings) {
        self.settings = settings.normalized()
    }

    public var shortcuts: ShortcutMap { ShortcutMap(overrides: settings.shortcuts) }
}
