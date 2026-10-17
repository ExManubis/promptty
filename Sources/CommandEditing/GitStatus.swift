import Foundation

/// A repository's state for the input bar's header: its HEAD (`GitHead`), then whether anything is
/// to commit (`git status`), which can take much longer to learn.
public struct GitStatus: Equatable, Sendable {
    /// The branch, or the short commit hash when HEAD is detached.
    public var branch: String
    /// Anything to commit: changed, staged or untracked files.
    public var dirty: Bool
    /// HEAD is a commit, not a branch: `branch` is its short hash.
    public var detached: Bool

    public init(branch: String, dirty: Bool, detached: Bool = false) {
        self.branch = branch
        self.dirty = dirty
        self.detached = detached
    }
}

/// What the header knows of HEAD, from `git symbolic-ref --short -q HEAD`: cheap even in a large
/// repository, where a full `git status` can take seconds.
public enum GitHead: Equatable, Sendable {
    case branch(String)
    /// HEAD is a commit: `git rev-parse --short HEAD` names it.
    case detached
    case notARepository
    /// git was too slow or was stopped: keep showing what was there.
    case unknown

    public init(symbolicRef outcome: ProcessRunner.Outcome) {
        switch outcome {
        case .exited(0, let output):
            let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
            self = name.isEmpty ? .unknown : .branch(name)
        case .exited(1, _): self = .detached
        // 128: not in a repository. No git at all reads the same.
        case .exited, .failedToStart: self = .notARepository
        case .timedOut, .stopped: self = .unknown
        }
    }
}

extension GitStatus {
    /// Whether `git status --porcelain=v2` (without `--branch`) found anything to commit; nil when
    /// it did not finish. Its first line answers, so the run can stop there (`dirtyEnough`).
    public static func dirty(fromStatus outcome: ProcessRunner.Outcome) -> Bool? {
        switch outcome {
        case .exited(0, let output): !output.isEmpty
        case .stopped: true
        case .exited, .timedOut, .failedToStart: nil
        }
    }

    /// Ends a `git status --porcelain=v2` run at its first line: one change makes the folder dirty.
    public static let dirtyEnough: @Sendable (Data) -> Bool = { !$0.isEmpty }
}
