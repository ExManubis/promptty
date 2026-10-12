/// A repository's state for the input bar's header, from `git status --porcelain=v2 --branch`.
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

    /// Nil when the output is not a status (not a repository).
    public static func parse(porcelainV2 output: String) -> GitStatus? {
        var head: String?
        var oid: String?
        var dirty = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                head = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.oid ") {
                oid = String(line.dropFirst("# branch.oid ".count))
            } else if !line.hasPrefix("#") {
                dirty = true
            }
        }
        guard let head else { return nil }
        let detached = head == "(detached)"
        let branch = detached ? String((oid ?? "").prefix(7)) : head
        return GitStatus(branch: branch, dirty: dirty, detached: detached)
    }
}
