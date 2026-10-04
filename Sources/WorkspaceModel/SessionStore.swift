import Foundation

public struct SessionStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PrompTTY", isDirectory: true).appendingPathComponent("session.json")
    }

    /// Returns nil when there is no session or it cannot be used. An unusable file is moved aside
    /// to `<name>.bak` so a bad file can never block launch twice.
    public func load() -> SessionSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let snap = try JSONDecoder().decode(SessionSnapshot.self, from: data)
            guard snap.version <= SessionSnapshot.currentVersion else { throw CocoaError(.coderInvalidValue) }
            return snap
        } catch {
            moveAside()
            return nil
        }
    }

    public func save(_ snapshot: SessionSnapshot) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    private func moveAside() {
        let bak = URL(fileURLWithPath: url.path + ".bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.moveItem(at: url, to: bak)
    }
}
