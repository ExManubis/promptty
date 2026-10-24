import Darwin
import Foundation

// Process inspection is Mac only; `ProcessTree`'s walk is shared.
#if os(macOS)
/// The TCP ports a pane's programs listen on (a dev server's `:3000`), read from the kernel with
/// libproc: no `lsof` per look.
public enum ListeningPorts {
    /// Processes looked at below `root`, at most: a pane's tree is small, a runaway one is not
    /// walked whole.
    static let maxProcesses = 64

    /// The ports `root` and the processes under it listen on, lowest first.
    public static func find(root: Int32) -> [Int] {
        find(root: root, in: ProcessTree.snapshot() ?? ProcessTree([]))
    }

    /// The same, from `processes`: one look at the process table, shared by every pane looked up
    /// at the same time.
    public static func find(root: Int32, in processes: ProcessTree) -> [Int] {
        var ports = Set<Int>()
        for pid in processes.descendants(of: root, limit: maxProcesses) {
            ports.formUnion(listening(pid))
        }
        return ports.sorted()
    }

    /// The ports `pid`'s TCP sockets listen on.
    static func listening(_ pid: Int32) -> Set<Int> {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }
        var ports = Set<Int>()
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports
    }
}
#endif

/// Which processes run under which, from one read of the kernel's process table: walking every
/// pane's tree from it costs one system call, where asking for each process's children scans the
/// whole table each time.
public struct ProcessTree: Sendable {
    private let children: [Int32: [Int32]]

    /// From (pid, parent pid) pairs.
    public init(_ processes: [(pid: Int32, parent: Int32)]) {
        var children: [Int32: [Int32]] = [:]
        for p in processes where p.pid > 0 && p.pid != p.parent { children[p.parent, default: []].append(p.pid) }
        self.children = children
    }

    #if os(macOS)
    /// Every process now; nil if the table cannot be read.
    public static func snapshot() -> ProcessTree? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        // The table can grow between asking its size and reading it: then ask again.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
            size = procs.count * stride
            if sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 {
                return ProcessTree(procs.prefix(size / stride).map { (pid: $0.kp_proc.p_pid, parent: $0.kp_eproc.e_ppid) })
            }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }
    #endif

    /// Whether anything runs under `pid` (a shell at its prompt has nothing).
    public func hasChildren(_ pid: Int32) -> Bool { children[pid]?.isEmpty == false }

    /// `root` and its descendants, breadth first, at most `limit`.
    public func descendants(of root: Int32, limit: Int) -> [Int32] {
        var out: [Int32] = [root]
        var index = 0
        while index < out.count, out.count < limit {
            out += (children[out[index]] ?? []).prefix(limit - out.count)
            index += 1
        }
        return out
    }
}
