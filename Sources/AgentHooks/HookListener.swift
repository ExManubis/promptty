import Darwin
import Foundation

/// Listens on the hook socket (mode 0600) for what `promptty-hook` sends: lines of JSON, each a
/// `HookMessage`. Reads off the caller's thread and hands each message to `deliver` on
/// `deliveryQueue` (the main queue in the app). Lines that are not messages are dropped; a peer
/// that is not the user's own process (`getpeereid`) is hung up on, as is one that sends too much
/// or takes too long.
public final class HookListener: @unchecked Sendable {
    public let path: String
    private let deliveryQueue: DispatchQueue
    private let deliver: @Sendable (HookMessage) -> Void
    private let allowsPeer: @Sendable (uid_t) -> Bool
    /// Everything below is touched only on this queue.
    private let queue = DispatchQueue(label: "dev.promptty.hooks", qos: .utility)
    private var listener: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]
    /// The socket file this listener made, to take away only that one.
    private var bound: (device: dev_t, inode: ino_t)?

    private final class Connection {
        let source: DispatchSourceRead
        var buffer = Data()
        var timeout: DispatchWorkItem?
        init(source: DispatchSourceRead) { self.source = source }
    }

    /// A message is a few hundred bytes; a line longer than this is not one.
    public static let maxLine = 64 * 1024
    static let maxConnections = 64
    /// The helper connects, writes and hangs up within 200 ms.
    static let timeout: TimeInterval = 2

    /// `allowsPeer` decides by the connecting process's user id: by default only the user's own.
    public init(path: String, deliveryQueue: DispatchQueue = .main, allowsPeer: @escaping @Sendable (uid_t) -> Bool = { $0 == getuid() },
                deliver: @escaping @Sendable (HookMessage) -> Void) {
        self.path = path
        self.deliveryQueue = deliveryQueue
        self.allowsPeer = allowsPeer
        self.deliver = deliver
    }

    public enum Failure: Error, Equatable {
        case socket(Int32)
        case pathTooLong
        /// Another app (a second PrompTTY on the same data folder) listens there already: its
        /// socket is left alone.
        case inUse
        /// The socket's folder is not the user's alone.
        case unsafeFolder
    }

    public func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard HookSocket.isSafeFolder(folder) else { throw Failure.unsafeFolder }
        guard let address = HookSocket.address(path) else { throw Failure.pathTooLong }
        if Self.answers(address) { throw Failure.inUse }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        // Not inherited by the shells the terminal starts.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        // Nobody answers: a socket left by an earlier run (a crash), which would keep the path taken.
        unlink(path)
        let bindResult = HookSocket.withSockaddr(address) { Darwin.bind(fd, $0, $1) }
        var info = stat()
        guard bindResult == 0, chmod(path, 0o600) == 0, lstat(path, &info) == 0, Darwin.listen(fd, 16) == 0 else {
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

    /// Stops listening and takes the socket away, unless it is no longer this listener's (another
    /// app took the path since).
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

    /// Whether something listens at the address.
    private static func answers(_ address: sockaddr_un) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return HookSocket.connect(fd, to: address)
    }

    private func acceptAll(on listening: Int32) {
        while true {
            let fd = accept(listening, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, allowsPeer(uid), connections.count < Self.maxConnections else {
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
            if !connection.buffer.isEmpty, connection.buffer.count <= Self.maxLine { handle(connection.buffer) }
            drop(fd)
            return
        }
        connection.buffer.append(chunk, count: n)
        while let newline = connection.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = connection.buffer[connection.buffer.startIndex..<newline]
            if line.count <= Self.maxLine { handle(line) }
            connection.buffer = Data(connection.buffer[connection.buffer.index(after: newline)...])
        }
        // A line this long is not a message: hang up rather than keep reading it.
        if connection.buffer.count > Self.maxLine { drop(fd) }
    }

    private func handle(_ line: Data) {
        guard let message = HookMessage.parse(line) else { return }
        let deliver = deliver
        deliveryQueue.async { deliver(message) }
    }

    private func drop(_ fd: Int32) {
        guard let connection = connections.removeValue(forKey: fd) else { return }
        connection.timeout?.cancel()
        connection.source.cancel()
    }
}

extension HookSocket {
    /// Whether a socket's folder is a real folder of the user's; the shared fallback in /tmp is
    /// also closed to everyone else (made so if it is not).
    public static func isSafeFolder(_ folder: String) -> Bool {
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return false }
        if folder == sharedFolder(), info.st_mode & 0o077 != 0 { return chmod(folder, 0o700) == 0 }
        return true
    }

    /// The Unix socket address of `path`; nil when the path is too long for one.
    public static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        return address
    }

    /// Connects the socket `fd` to `address`; whether it did.
    public static func connect(_ fd: Int32, to address: sockaddr_un) -> Bool {
        withSockaddr(address) { Darwin.connect(fd, $0, $1) } == 0
    }

    /// `body` with the address as the `sockaddr` and length that `bind` and `connect` take.
    public static func withSockaddr<R>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
