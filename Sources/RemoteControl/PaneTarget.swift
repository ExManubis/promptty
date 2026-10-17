import Foundation

/// Finds the pane `-p` (or `-b`) names, as Rex resolves its targets: a full id, then a label, then
/// the end of an id (at least 4 characters). Matching is case-insensitive, and Rex's `block:`
/// before a pane's id is optional.
public enum PaneTarget {
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let label: String?

        public init(id: String, label: String?) {
            self.id = id
            self.label = label
        }
    }

    public enum Resolution: Equatable, Sendable {
        case found(String)
        case missing
        case ambiguous([String])
    }

    public static func resolve(_ query: String, among candidates: [Candidate]) -> Resolution {
        var q = query.lowercased()
        if q.hasPrefix(ControlEnvironment.blockPrefix) { q.removeFirst(ControlEnvironment.blockPrefix.count) }
        guard !q.isEmpty else { return .missing }
        if let exact = candidates.first(where: { $0.id.lowercased() == q }) { return .found(exact.id) }
        let labelled = candidates.filter { $0.label?.lowercased() == q }
        if labelled.count == 1 { return .found(labelled[0].id) }
        if labelled.count > 1 { return .ambiguous(labelled.map(\.id)) }
        guard q.count >= 4 else { return .missing }
        let suffixed = candidates.filter { $0.id.lowercased().hasSuffix(q) }
        switch suffixed.count {
        case 0: return .missing
        case 1: return .found(suffixed[0].id)
        default: return .ambiguous(suffixed.map(\.id))
        }
    }
}
