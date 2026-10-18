import Foundation

/// A program's own report of what it does (OSC 7501, the Program Status Protocol:
/// https://www.superlogical.com/rex/docs/build/program-status), as libghostty decodes it. Its text
/// is the program's, untrusted: shown as plain text, never as markup.
public struct ProgramStatusReport: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle, working, done, blocked, error
        /// Removes the record and every record under it; without an id, every record.
        case clear
    }

    /// What a blocked program needs from the user.
    public enum Kind: Equatable, Sendable { case permission, question, auth }

    public var state: State
    public var kind: Kind?
    /// 0...100 while working or blocked; nil when the program gave none.
    public var progress: Int?
    /// The record the report is about, `/` separating levels; nil for the program's own.
    public var id: String?
    public var app: String?
    public var title: String?
    public var message: String?

    public init(state: State, kind: Kind? = nil, progress: Int? = nil, id: String? = nil, app: String? = nil,
                title: String? = nil, message: String? = nil) {
        self.state = state
        self.kind = kind
        self.progress = progress
        self.id = id
        self.app = app
        self.title = title
        self.message = message
    }

    /// The report as the pane's activity takes an agent's: what it does, and what it says.
    public var agentReport: PaneActivity.AgentReport? {
        switch state {
        case .idle: .ready
        case .working: .working(tool: title)
        case .blocked: kind == .permission ? .permission(message ?? title) : .waitingForInput(message ?? title)
        case .done: .turnEnded
        case .error: .failed(message ?? title)
        case .clear: nil
        }
    }
}

/// The program status records of one pane: one per id, each replaced whole by the next report
/// about it. Work underway ends with the program or at the next prompt; finished work (done, an
/// error) stays until the user has seen the pane.
public struct ProgramStatusRecords: Equatable, Sendable {
    public struct Record: Equatable, Sendable {
        public let report: ProgramStatusReport
        /// When the record's state began: a report repeating the state keeps it.
        public let since: Date
    }

    /// Records past this many evict the one least recently reported.
    static let capacity = 256

    /// By id; the program's own record is "".
    private var records: [String: Record] = [:]
    /// Ids, least recently reported first.
    private var order: [String] = []

    public init() {}

    public var isEmpty: Bool { records.isEmpty }
    public var count: Int { records.count }

    public mutating func apply(_ report: ProgramStatusReport, at now: Date) {
        let key = report.id ?? ""
        guard report.state != .clear else {
            if report.id == nil {
                records = [:]
                order = []
            } else {
                remove { id, _ in id == key || id.hasPrefix(key + "/") }
            }
            return
        }
        let since = records[key].flatMap { $0.report.state == report.state ? $0.since : nil } ?? now
        records[key] = Record(report: report, since: since)
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > Self.capacity { records[order.removeFirst()] = nil }
    }

    /// A new prompt, or the program that reported quit: its work is no longer underway.
    public mutating func endWork() {
        remove { _, record in [.working, .blocked].contains(record.report.state) }
    }

    /// The user saw the pane: what finished there has been looked at.
    public mutating func seen() {
        remove { _, record in [.done, .error].contains(record.report.state) }
    }

    /// The record the pane shows: the most urgent, the program's own among equals.
    public var current: Record? {
        records.max { a, b in
            let (ra, rb) = (Self.rank(a.value.report), Self.rank(b.value.report))
            return ra != rb ? ra < rb : (a.key != "" && b.key == "")
        }?.value
    }

    private static func rank(_ report: ProgramStatusReport) -> Int {
        switch report.state {
        case .blocked: report.kind == .permission ? 6 : 5
        case .error: 4
        case .working: 3
        case .done: 2
        case .idle: 1
        case .clear: 0
        }
    }

    private mutating func remove(where match: (String, Record) -> Bool) {
        let gone = records.filter { match($0.key, $0.value) }.keys
        guard !gone.isEmpty else { return }
        for key in gone { records[key] = nil }
        order.removeAll { records[$0] == nil }
    }
}
