import Darwin
import Foundation

/// A process's executable and arguments, read from the kernel.
public struct ProcessArguments: Equatable, Sendable {
    public let executable: String
    /// The full argv, the program's own name first.
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// Nil when the process is gone or not ours to read (one run by another user, as with sudo).
    public static func read(pid: Int32) -> ProcessArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        // Most argument lists fit in 64 KB; the kernel's maximum is a megabyte.
        var size = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &buffer, &size, nil, 0) != 0 {
            guard errno == ENOMEM, sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return nil }
            buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        }
        return parse(Array(buffer[0..<size]))
    }

    /// The folder a process works in (an agent started with `cd x && claude` is in `x`, which the
    /// shell never reported). Nil when the process is gone or not ours.
    public static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }

    /// `KERN_PROCARGS2`'s layout: argc, the executable path, NUL padding, then argc arguments,
    /// each ending in one NUL (the environment follows). A program that rewrote its argv (node's
    /// `process.title`) leaves NULs where arguments were: those read as empty.
    public static func parse(_ bytes: [UInt8]) -> ProcessArguments? {
        let header = MemoryLayout<Int32>.size
        guard bytes.count > header else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = header
        func string() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return value
        }
        guard let executable = string(), !executable.isEmpty else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<max(0, min(Int(argc), 4096)) {
            guard let argument = string() else { break }
            arguments.append(argument)
        }
        return ProcessArguments(executable: executable, arguments: arguments)
    }
}
