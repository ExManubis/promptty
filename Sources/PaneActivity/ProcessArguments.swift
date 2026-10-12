import Darwin
import Foundation

/// A process's executable and arguments, read from the kernel.
public struct ProcessArguments: Equatable, Sendable {
    public let executable: String
    /// The full argv, the program's own name first.
    public let arguments: [String]

    /// Nil when the process is gone or not ours to read.
    public static func read(pid: Int32) -> ProcessArguments? {
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // argc, then the executable path, NUL padding, then argc NUL-terminated arguments.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        func string() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let value = String(decoding: buffer[start..<index], as: UTF8.self)
            while index < size, buffer[index] == 0 { index += 1 }
            return value
        }
        guard let executable = string() else { return nil }
        var arguments: [String] = []
        for _ in 0..<max(argc, 0) {
            guard let argument = string() else { break }
            arguments.append(argument)
        }
        return ProcessArguments(executable: executable, arguments: arguments)
    }
}
