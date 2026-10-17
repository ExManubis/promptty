import Darwin
import Foundation

/// The TCP ports a pane's programs listen on (a dev server's `:3000`), read from the kernel with
/// libproc: no `lsof` per look.
public enum ListeningPorts {
    /// Processes looked at below `root`, at most: a pane's tree is small, a runaway one is not
    /// walked whole.
    static let maxProcesses = 64

    /// The ports `root` and the processes under it listen on, lowest first.
    public static func find(root: Int32) -> [Int] {
        var ports = Set<Int>()
        for pid in tree(root) {
            ports.formUnion(listening(pid))
        }
        return ports.sorted()
    }

    /// Whether anything runs under `pid` (a shell at its prompt has nothing).
    public static func hasChildren(_ pid: Int32) -> Bool { !children(of: pid).isEmpty }

    /// `root` and its descendants, breadth first, at most `maxProcesses`.
    static func tree(_ root: Int32) -> [Int32] {
        var out: [Int32] = [root]
        var index = 0
        while index < out.count, out.count < maxProcesses {
            out += children(of: out[index]).prefix(maxProcesses - out.count)
            index += 1
        }
        return out
    }

    static func children(of pid: Int32) -> [Int32] {
        var buffer = [Int32](repeating: 0, count: 64)
        let bytes = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        // Returns a count of pids on current systems (bytes on old ones); never more than fit.
        let count = min(Int(bytes), buffer.count)
        return buffer.prefix(count).filter { $0 > 0 }
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
