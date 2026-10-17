import AgentHooks
import Darwin
import Foundation

/// The control socket (mode 0600, the user's own processes only): `promptty` connects, writes one
/// request line, reads one response line, hangs up. Unlike the hook socket it answers.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest, @escaping @Sendable (ControlResponse) -> Void) -> Void

    public let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.promptty.control", qos: .userInitiated)
    private var listener: DispatchSourceRead?

    /// A request is a command and a few words; a capture answer can be the whole scrollback.
    static let maxRequest = 1 << 20
    static let timeout: TimeInterval = 10

    /// `handler` is called on the main queue and must call its completion once.
    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public enum Failure: Error, Equatable { case socket(Int32), pathTooLong, inUse }

    public func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
        guard HookSocket.withSockaddr(address, { Darwin.bind(fd, $0, $1) }) == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            let error = errno
            close(fd)
            throw Failure.socket(error)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(on: fd) }
        source.setCancelHandler { close(fd) }
        listener = source
        source.resume()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        unlink(path)
    }

    private func acceptAll(on listening: Int32) {
        while true {
            let fd = accept(listening, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            // Accepted sockets inherit the listener's non-blocking mode; this one waits (with a
            // timeout) for its request.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Each connection on its own: a slow client holds up nobody.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        var timeout = timeval(tv_sec: Int(Self.timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let line = ControlWire.readLine(fd, limit: Self.maxRequest),
              let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
            close(fd)
            return
        }
        let handler = self.handler
        DispatchQueue.main.async {
            handler(request) { response in
                DispatchQueue.global(qos: .userInitiated).async {
                    if let data = try? JSONEncoder().encode(response) { ControlWire.write(data + Data([0x0A]), to: fd) }
                    close(fd)
                }
            }
        }
    }
}

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
