import GhosttyKit

/// Build information from the linked libghostty. Exists mainly to prove linking works.
public enum GhosttyInfo {
    public static var version: String {
        let info = ghostty_info()
        guard let ptr = info.version else { return "" }
        let buffer = UnsafeBufferPointer(start: ptr, count: Int(info.version_len))
        return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
