import Foundation

/// What a pane is doing, as far as its tab and header show it: whether something runs in it, and
/// what happened there that the user has not seen yet.
public struct PaneActivity: Equatable, Sendable {
    /// What the indicator shows, least to most urgent; a tab shows its most urgent pane.
    public enum Display: Equatable, Comparable, Sendable {
        case idle
        case running
        case finished
        case failed(Int)
        case attention

        private var rank: Int {
            switch self {
            case .idle: 0
            case .running: 1
            case .finished: 2
            case .failed: 3
            case .attention: 4
            }
        }

        public static func < (a: Display, b: Display) -> Bool { a.rank < b.rank }
    }

    /// The pane's foreground process.
    public enum Foreground: Equatable, Sendable {
        case shell
        /// A program PrompTTY does not recognise.
        case command
        case program(Program)
    }

    private enum Unseen: Equatable, Sendable {
        case finished
        case failed(Int)
        case attention
    }

    /// The recognised program that runs, if any.
    public private(set) var program: Program?
    public private(set) var isRunning = false
    private var startedAt: Date?
    private var unseen: Unseen?
    /// The shell reported the command's exit status before the shell was seen back in front.
    private var pendingExit: Int?

    /// Commands that take at least this long notify when they finish unseen.
    public static let notifyAfter: TimeInterval = 10

    public init() {}

    public var display: Display {
        switch unseen {
        case .attention: .attention
        case .failed(let code): .failed(code)
        case .finished: .finished
        case nil: isRunning ? .running : .idle
        }
    }

    /// The foreground process, polled. Returns the notice to post when a long command finished
    /// where the user was not looking.
    @discardableResult
    public mutating func observe(_ foreground: Foreground, at now: Date, seen: Bool) -> Notice? {
        switch foreground {
        case .shell:
            guard isRunning else { return nil }
            let ran = program
            let duration = startedAt.map { now.timeIntervalSince($0) } ?? 0
            let code = pendingExit ?? 0
            isRunning = false
            program = nil
            startedAt = nil
            pendingExit = nil
            guard !seen else { return nil }
            if unseen != .attention { unseen = code == 0 ? .finished : .failed(code) }
            guard duration >= Self.notifyAfter else { return nil }
            return Notice(kind: code == 0 ? .finished : .failed(code), program: ran, duration: duration)
        case .command, .program:
            if case .program(let p) = foreground { program = p } else { program = nil }
            if !isRunning {
                isRunning = true
                startedAt = now
                pendingExit = nil
            }
            return nil
        }
    }

    /// The shell reported how the last command ended (it can arrive just before or just after the
    /// shell is seen back in front).
    public mutating func exitReported(code: Int) {
        if isRunning {
            pendingExit = code
        } else if unseen == .finished, code != 0 {
            unseen = .failed(code)
        }
    }

    /// A bell, or a program's notification (an agent waiting for the user).
    @discardableResult
    public mutating func attention(seen: Bool, message: String?) -> Notice? {
        guard !seen else { return nil }
        unseen = .attention
        return Notice(kind: .attention(message), program: program, duration: nil)
    }

    /// The user looked at the pane.
    public mutating func seen() {
        unseen = nil
    }
}

/// A macOS notification about a pane.
public struct Notice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case finished
        case failed(Int)
        case attention(String?)
    }

    public let kind: Kind
    public let program: Program?
    public let duration: TimeInterval?

    public init(kind: Kind, program: Program?, duration: TimeInterval?) {
        self.kind = kind
        self.program = program
        self.duration = duration
    }

    /// The program's name, or the command that ran, or a plain word.
    public func title(command: String?) -> String {
        if let program { return program.name }
        if let command, !command.isEmpty { return command }
        return "Command"
    }

    public var body: String {
        switch kind {
        case .finished: "Finished in \(Self.format(duration ?? 0))"
        case .failed(let code): "Failed (exit \(code)) after \(Self.format(duration ?? 0))"
        case .attention(let message): message.flatMap { $0.isEmpty ? nil : $0 } ?? "Needs your attention"
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min \(total % 60) s" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
