import Foundation

/// The file system side of completion: read off the main thread, once per completion list.
public enum DirectoryListing {
    /// The directory's entries. A symlink counts as a folder when its target is one (`/tmp`,
    /// `/etc`, a linked project), as the shell treats it.
    public static func entries(inDirectory path: String) -> [(name: String, isDirectory: Bool)] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        return items.map { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            var isDirectory = values?.isDirectory == true
            if values?.isSymbolicLink == true {
                // `isDirectoryKey` describes the link itself; this follows it.
                var target: ObjCBool = false
                isDirectory = FileManager.default.fileExists(atPath: item.path, isDirectory: &target) && target.boolValue
            }
            return (name: item.lastPathComponent, isDirectory: isDirectory)
        }
    }
}
