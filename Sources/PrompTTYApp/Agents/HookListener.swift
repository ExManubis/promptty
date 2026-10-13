import AgentHooks
import Darwin
import Foundation

/// Listens on the hook socket (`AppPaths.hookSocket`, mode 0600) for what `promptty-hook` sends:
/// lines of JSON, each a `HookMessage`. Reads off the main thread and hands each message to
/// `deliver` on the main thread. Lines that are not messages are dropped; a peer that is not the
/// user's own process (`getpeereid`) is hung up on, as is one that sends too much or takes too long.
final class HookListener: @unchecked Sendable {
    let path: String
    private let deliver: @MainActor @Sendable (HookMessage) -> Void
    /// Everything below is touched only on this queue.
    private let queue = DispatchQueue(label: "dev.promptty.hooks", qos: .utility)
    private var listener: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    private final class Connection {
        let source: DispatchSourceRead
        var buffer = Data()
        var timeout: DispatchWorkItem?
        init(source: DispatchSourceRead) { self.source = source }
    }

    /// A message is a few hundred bytes; a line longer than this is not one.
    static let maxLine = 64 * 1024
    static let maxConnections = 64
    /// The helper connects, writes and hangs up within 200 ms.
    static let timeout: TimeInterval = 2

    init(path: String, deliver: @escaping @MainActor @Sendable (HookMessage) -> Void) {
        self.path = path
        self.deliver = deliver
    }

    enum Failure: Error { case socket(Int32), pathTooLong }

    func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        // Not inherited by the shells the terminal starts.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // A socket left by an earlier run (a crash) would keep the path taken.
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            let error = errno
            close(fd)
            throw Failure.socket(error)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(on: fd) }
        source.setCancelHandler { close(fd) }
        queue.sync { listener = source }
        source.resume()
    }

    /// Stops listening and takes the socket away.
    func stop() {
        queue.sync {
            for fd in Array(connections.keys) { drop(fd) }
            listener?.cancel()
            listener = nil
        }
        unlink(path)
    }

    private func acceptAll(on listening: Int32) {
        while true {
            let fd = accept(listening, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(), connections.count < Self.maxConnections else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let connection = Connection(source: source)
            connections[fd] = connection
            source.setEventHandler { [weak self] in self?.read(fd) }
            source.setCancelHandler { close(fd) }
            let timeout = DispatchWorkItem { [weak self] in self?.drop(fd) }
            connection.timeout = timeout
            queue.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)
            source.resume()
        }
    }

    private func read(_ fd: Int32) {
        guard let connection = connections[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n < 0, errno == EAGAIN || errno == EINTR { return }
        guard n > 0 else {
            // The end: a last line without its newline counts too.
            if !connection.buffer.isEmpty { handle(connection.buffer) }
            drop(fd)
            return
        }
        connection.buffer.append(chunk, count: n)
        while let newline = connection.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            handle(connection.buffer[connection.buffer.startIndex..<newline])
            connection.buffer = Data(connection.buffer[connection.buffer.index(after: newline)...])
        }
        if connection.buffer.count > Self.maxLine { drop(fd) }
    }

    private func handle(_ line: Data) {
        guard let message = HookMessage.parse(line) else { return }
        let deliver = deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(message) } }
    }

    private func drop(_ fd: Int32) {
        guard let connection = connections.removeValue(forKey: fd) else { return }
        connection.timeout?.cancel()
        connection.source.cancel()
    }
}
