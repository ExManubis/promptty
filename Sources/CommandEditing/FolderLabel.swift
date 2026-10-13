import Foundation

/// The input bar's folder button: the folder short enough to sit beside the branch.
public enum FolderLabel {
    /// Home as `~`; a path more than three levels deep (counting `~`) as its last two folders
    /// after an ellipsis: `…/acme/web`.
    public static func short(_ path: String, home: String) -> String {
        var display = path
        if path == home {
            display = "~"
        } else if path.hasPrefix(home + "/") {
            display = "~" + path.dropFirst(home.count)
        }
        let parts = display.split(separator: "/")
        guard parts.count > 3 else {
            // `/x/y/`: the same folder without its trailing slash.
            return display.count > 1 && display.hasSuffix("/") ? String(display.dropLast()) : display
        }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }
}
