import Foundation
import SessionProtocol

/// A connection to the daemon (the app). Everything here runs on the daemon's queue; writes
/// never block it: what the socket won't take yet waits, and a peer too far behind is hung up on.
final class Peer {
    let id: Int
    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writing = false
    private var pending = Data()
    var reader = SessionFrameReader()
    var introduced = false
    /// The panes whose output goes to this peer.
    var panes: Set<UUID> = []
    private(set) var closed = false

    /// More than this waiting to be written: the peer stopped reading.
    static let maxPending = 64 << 20

    init(id: Int, fd: Int32, queue: DispatchQueue) {
        self.id = id
        self.fd = fd
        self.queue = queue
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads until the peer goes; `onBytes` gets what came, `onClose` runs once.
    func start(onBytes: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let count = read(self.fd, &buffer, buffer.count)
                if count > 0 {
                    onBytes(Data(buffer[0..<count]))
                    if self.closed { return }
                } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                    return
                } else {
                    self.close()
                    onClose()
                    return
                }
            }
        }
        readSource = source
        source.resume()
    }

    func send(_ frame: Data) {
        guard !closed else { return }
        pending.append(frame)
        if pending.count > Self.maxPending {
            close()
            return
        }
        flush()
    }

    private func flush() {
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                pending.removeFirst(written)
            } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                waitForRoom()
                return
            } else {
                close()
                return
            }
        }
        pending = Data()
    }

    private func waitForRoom() {
        guard !writing else { return }
        writing = true
        if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.writeSource?.suspend()
                self.writing = false
                self.flush()
            }
            writeSource = source
            source.resume()
        } else {
            writeSource?.resume()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        // A suspended source must be resumed before it can be cancelled.
        if let writeSource {
            if !writing { writeSource.resume() }
            writeSource.cancel()
        }
        // The descriptor is closed once the sources watching it are cancelled.
        let fd = fd
        if let readSource {
            readSource.setCancelHandler { Darwin.close(fd) }
            readSource.cancel()
        } else {
            Darwin.close(fd)
        }
        pending = Data()
    }
}
