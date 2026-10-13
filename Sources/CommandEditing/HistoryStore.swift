import Foundation

/// Where the last read of a history file stopped, so the next one can read only what was added.
struct HistoryFileState: Sendable {
    var size = -1
    var date: Date?
    /// Bytes consumed: the file up to here ends at a complete entry.
    var offset = 0
    /// The bytes just before `offset`; if they are not there any more the file was rewritten.
    var fingerprint: [UInt8] = []
}

enum HistoryFileRead: Sendable {
    case unchanged
    case appended([String], HistoryFileState)
    case replaced(HistoryLayer, HistoryFileState)
}

/// Reads a history file, all of it or only what was added since the last read. Runs off the main
/// thread; everything it returns is already parsed and de-duplicated.
enum HistoryFileReader {
    private static let fingerprintLength = 64

    static func read(path: String, since state: HistoryFileState) -> HistoryFileRead {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue else { return .unchanged }
        let date = attributes[.modificationDate] as? Date
        if size == state.size, date == state.date { return .unchanged }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unchanged }
        defer { try? handle.close() }

        var next = HistoryFileState(size: size, date: date)
        var body: Data?
        var base = 0
        var lead: [UInt8] = []
        if state.offset > 0, size >= state.offset, !state.fingerprint.isEmpty {
            let from = state.offset - state.fingerprint.count
            if (try? handle.seek(toOffset: UInt64(from))) != nil, let data = try? handle.readToEnd(),
               data.count >= state.fingerprint.count, Array(data.prefix(state.fingerprint.count)) == state.fingerprint {
                body = Data(data.dropFirst(state.fingerprint.count))
                base = state.offset
                lead = state.fingerprint
            }
        }
        let incremental = body != nil
        if body == nil {
            guard (try? handle.seek(toOffset: 0)) != nil, let data = try? handle.readToEnd() else { return .unchanged }
            body = data
        }
        let data = body ?? Data()
        // An entry still being written (no newline yet, or a backslash continuing it) waits for the next read.
        let complete = data.prefix(completeLength(of: data))
        let entries = ZshHistory.parse(Data(complete))
        next.offset = base + complete.count
        next.fingerprint = Array((lead + complete).suffix(fingerprintLength))
        return incremental ? .appended(entries, next) : .replaced(HistoryLayer(entries), next)
    }

    /// The length of the prefix that ends at a newline which ends an entry.
    private static func completeLength(of data: Data) -> Int {
        var index = data.endIndex
        while index > data.startIndex {
            let last = data.index(before: index)
            if data[last] == 0x0A, last == data.startIndex || data[data.index(before: last)] != 0x5C { return index - data.startIndex }
            index = last
        }
        return 0
    }
}

/// One history per HISTFILE, shared by the panes that use it: the file is parsed and
/// de-duplicated once, off the main thread, and a command run in one pane is offered in the others.
/// A pane holds its store; the registry does not, so a store ends with its last pane (what zsh has
/// written to the file stays; the next store reads it).
@MainActor
public final class HistoryStore {
    private final class Entry { weak var store: HistoryStore? }
    private static var registry: [String: Entry] = [:]

    /// The store for a history file (`~` allowed), made on first use.
    public static func shared(forPath path: String) -> HistoryStore {
        let key = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        registry = registry.filter { $0.value.store != nil }
        if let store = registry[key]?.store { return store }
        let store = HistoryStore(path: key)
        let entry = Entry()
        entry.store = store
        registry[key] = entry
        return store
    }

    /// Nil for a store that is not backed by a file (a pane that has not learned its HISTFILE yet).
    public let path: String?
    public let history = CommandHistory()
    /// Unique commands, newest first.
    public var newestFirst: [String] { history.newestFirst }
    /// Changes whenever `newestFirst` does.
    public var version: Int { history.version }

    private var fileState = HistoryFileState()
    private var loading: Task<Void, Never>?
    private var reloadAgain = false
    private(set) var reloadCount = 0
    private(set) var lastReloadWasIncremental: Bool?

    public init(path: String? = nil) {
        self.path = path
    }

    public func add(_ command: String) {
        history.add(command)
    }

    /// What panes added to this store, oldest first.
    public var sessionCommands: [String] { history.sessionCommands }

    /// Takes over commands from the store a pane moves away from.
    public func adopt(_ commands: [String]) {
        for command in commands { history.add(command) }
    }

    /// Reads the file if it changed. Calls while a read is under way wait for it and ask for one
    /// more afterwards, however many there were.
    public func reload() async {
        guard let path else { return }
        if let loading {
            reloadAgain = true
            await loading.value
            return
        }
        let task = Task { [weak self] in
            repeat {
                guard let self else { return }
                self.reloadAgain = false
                let state = self.fileState
                let outcome = await Task.detached(priority: .utility) { HistoryFileReader.read(path: path, since: state) }.value
                self.apply(outcome)
            } while self?.reloadAgain == true
            self?.loading = nil
        }
        loading = task
        await task.value
    }

    /// Fire and forget, from the shell's prompt.
    public func reloadIfChanged() {
        Task { await reload() }
    }

    private func apply(_ outcome: HistoryFileRead) {
        reloadCount += 1
        switch outcome {
        case .unchanged:
            break
        case .appended(let entries, let state):
            fileState = state
            lastReloadWasIncremental = true
            history.appendFileEntries(entries)
        case .replaced(let layer, let state):
            fileState = state
            lastReloadWasIncremental = false
            history.replaceFile(layer)
        }
    }
}
