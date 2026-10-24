import AgentHooks
import Darwin
import Foundation

// The server runs in the Mac app only; the client below is shared.
#if os(macOS)
/// The control socket (mode 0600, the user's own processes only): `promptty` connects, writes one
/// request line, reads one response line, hangs up. Unlike the hook socket it answers. Requests
/// are read off the main thread without blocking one; a peer that is not the user's own process
/// (`getpeereid`), or that sends too much or takes too long, is hung up on.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest, @escaping @Sendable (ControlResponse) -> Void) -> Void

    public let path: String
    private let handler: Handler
    /// Everything below is touched only on this queue.
    private let queue = DispatchQueue(label: "dev.promptty.control", qos: .userInitiated)
    private var listener: DispatchSourceRead?
    /// Connections still sending their request.
    private var connections: [Int32: Connection] = [:]
    /// The socket file this server made, to take away only that one.
    private var bound: (device: dev_t, inode: ino_t)?

    private final class Connection {
        let source: DispatchSourceRead
        var buffer = Data()
        var timeout: DispatchWorkItem?
        let handoff: Handoff
        init(source: DispatchSourceRead, handoff: Handoff) { self.source = source; self.handoff = handoff }
    }

    /// The request read from a connection: once its read source is cancelled, the descriptor
    /// stays open for the answer, which closes it.
    private final class Handoff: @unchecked Sendable { var request: ControlRequest? }

    /// A request is a command and a few words; a capture answer can be the whole scrollback.
    static let maxRequest = 1 << 20
    /// Connections sending a request at once; those waiting for an answer (`wait`) do not count.
    static let maxConnections = 64
    static let timeout: TimeInterval = 10

    /// `handler` is called on the main queue and must call its completion once.
    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public enum Failure: Error, Equatable {
        case socket(Int32), pathTooLong, inUse
        /// The socket's folder is not the user's alone.
        case unsafeFolder
    }

    public func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard HookSocket.isSafeFolder(folder) else { throw Failure.unsafeFolder }
        guard let address = HookSocket.address(path) else { throw Failure.pathTooLong }
        // Another PrompTTY on the same data folder: its socket is left alone.
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        if probe >= 0 {
            defer { close(probe) }
            if HookSocket.connect(probe, to: address) { throw Failure.inUse }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        unlink(path)
        var info = stat()
        guard HookSocket.withSockaddr(address, { Darwin.bind(fd, $0, $1) }) == 0, chmod(path, 0o600) == 0, lstat(path, &info) == 0,
              Darwin.listen(fd, 16) == 0 else {
            let error = errno
            close(fd)
            throw Failure.socket(error)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(on: fd) }
        source.setCancelHandler { close(fd) }
        queue.sync {
            listener = source
            bound = (info.st_dev, info.st_ino)
        }
        source.resume()
    }

    /// Stops listening and takes the socket away, unless it is no longer this server's (another
    /// app took the path since). Requests already handed over are still answered.
    public func stop() {
        let mine: (device: dev_t, inode: ino_t)? = queue.sync {
            for fd in Array(connections.keys) { drop(fd) }
            listener?.cancel()
            listener = nil
            defer { bound = nil }
            return bound
        }
        var info = stat()
        if let mine, lstat(path, &info) == 0, info.st_dev == mine.device, info.st_ino == mine.inode { unlink(path) }
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
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let handoff = Handoff()
            let connection = Connection(source: source, handoff: handoff)
            connections[fd] = connection
            source.setEventHandler { [weak self] in self?.read(fd) }
            // Only once the source lets go of the descriptor may it be answered on (and closed).
            let handler = handler
            source.setCancelHandler {
                if let request = handoff.request { Self.answer(request, on: fd, handler: handler) } else { close(fd) }
            }
            let timeout = DispatchWorkItem { [weak self] in self?.drop(fd) }
            connection.timeout = timeout
            queue.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)
            source.resume()
        }
    }

    private func read(_ fd: Int32) {
        guard let connection = connections[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n < 0, errno == EAGAIN || errno == EINTR { return }
        guard n > 0 else {
            // The end: a request without its newline counts too.
            if !connection.buffer.isEmpty { handOver(fd, line: connection.buffer) } else { drop(fd) }
            return
        }
        if let newline = chunk[0..<n].firstIndex(of: 0x0A) {
            connection.buffer.append(contentsOf: chunk[0..<newline])
            handOver(fd, line: connection.buffer)
            return
        }
        connection.buffer.append(contentsOf: chunk[0..<n])
        if connection.buffer.count > Self.maxRequest { drop(fd) }
    }

    /// The request is read: it is answered once the connection's source is cancelled.
    private func handOver(_ fd: Int32, line: Data) {
        guard line.count <= Self.maxRequest, let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else { return drop(fd) }
        connections[fd]?.handoff.request = request
        drop(fd)
    }

    /// The handler answers on the main queue; the answer is written (blocking, with a timeout) off
    /// it, then the connection is closed.
    private static func answer(_ request: ControlRequest, on fd: Int32, handler: @escaping Handler) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: Int(Self.timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        DispatchQueue.main.async {
            handler(request) { response in
                DispatchQueue.global(qos: .userInitiated).async {
                    if let data = try? JSONEncoder().encode(response) { ControlWire.write(data + Data([0x0A]), to: fd) }
                    close(fd)
                }
            }
        }
    }

    private func drop(_ fd: Int32) {
        guard let connection = connections.removeValue(forKey: fd) else { return }
        connection.timeout?.cancel()
        connection.source.cancel()
    }
}
#endif


/// `promptty`'s side: one request, one answer; nil when the app cannot be reached.
public enum ControlClient {
    public static func send(_ request: ControlRequest, to path: String, timeout: TimeInterval = 15) -> ControlResponse? {
        guard let address = HookSocket.address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard HookSocket.connect(fd, to: address), let data = try? JSONEncoder().encode(request) else { return nil }
        // Only the user's own app hears what is sent (it can be text for a terminal): a socket
        // another user put in the path is not it.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return nil }
        ControlWire.write(data + Data([0x0A]), to: fd)
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        guard let line = ControlWire.readLine(fd, limit: 64 << 20) else { return nil }
        return try? JSONDecoder().decode(ControlResponse.self, from: line)
    }
}

enum ControlWire {
    /// Bytes up to the first newline (not included), or to the end; nil past `limit` or on error.
    static func readLine(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= limit {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                if let newline = buffer[0..<n].firstIndex(of: 0x0A) {
                    data.append(contentsOf: buffer[0..<newline])
                    return data
                }
                data.append(contentsOf: buffer[0..<n])
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return n == 0 && !data.isEmpty ? data : nil
            }
        }
        return nil
    }

    static func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { break }
            }
        }
    }
}
