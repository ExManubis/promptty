import Foundation

/// The pickers' filter: names that start with the typed text (ignoring case) first, then names
/// that contain it, each group in the order given.
public enum PickerFilter {
    public static func filter(_ names: [String], query: String) -> [String] {
        var prefix: [String] = []
        var other: [String] = []
        for name in names {
            guard let range = name.range(of: query, options: .caseInsensitive) else { continue }
            if range.lowerBound == name.startIndex { prefix.append(name) } else { other.append(name) }
        }
        return prefix + other
    }
}
