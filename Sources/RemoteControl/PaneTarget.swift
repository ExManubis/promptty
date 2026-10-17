import Foundation

/// Finds the pane `-p` names, as Rex resolves its targets: a full id, then a label, then the end
/// of an id (at least 4 characters). Matching is case-insensitive.
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
        let q = query.lowercased()
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
