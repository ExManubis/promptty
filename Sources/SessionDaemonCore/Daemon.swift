import Foundation
import os
import SessionProtocol

/// prompttyd: listens on a Unix socket for the app, runs each pane's program on a pty of its own
/// (`Session`) and keeps it running when the app goes. Everything runs on one queue. With no
/// session left and no app connected for a while, it exits.
public final class Daemon {
    private let socketPath: String
    private let queue = DispatchQueue(label: "dev.promptty.prompttyd", qos: .userInitiated)
    private var listener: DispatchSourceRead?
    private var peers: [Int: Peer] = [:]
    private var sessions: [UUID: Session] = [:]
    private var lastPeerID = 0
    private var idleExit: DispatchWorkItem?
    private var statusTimer: DispatchSourceTimer?
    private let build: String
    private static let log = Logger(subsystem: "dev.promptty.prompttyd", category: "daemon")

    /// How long it waits, with nothing to run and no app, before it exits.
    static let idleTimeout: TimeInterval = 15

    public enum Failure: Error, CustomStringConvertible {
        case socket(String)
        case running

        public var description: String {
            switch self {
            case .socket(let why): "can't listen: \(why)"
            case .running: "another prompttyd answers on the socket"
            }
        }
    }

    public init(socketPath: String) {
        self.socketPath = socketPath
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let modified = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        build = modified.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
    }

    public func start() throws {
        try queue.sync {
            if Self.answers(socketPath) { throw Failure.running }
            unlink(socketPath)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.socket(String(cString: strerror(errno))) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(socketPath.utf8CString)
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                close(fd)
                throw Failure.socket("the socket path is too long")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(fd, 16) == 0 else {
                let why = String(cString: strerror(errno))
                close(fd)
                throw Failure.socket(why)
            }
            // Only this user.
            chmod(socketPath, 0o600)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.accept(fd) }
            listener = source
            source.resume()

            // Whether a program reads a password changes without output: looked at a few times a
            // second while the app watches.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                for session in self.sessions.values where !session.peers.isEmpty { session.refreshStatus(checkingMode: true) }
            }
            statusTimer = timer
            timer.resume()
            scheduleIdleExit()
        }
        Self.log.info("listening on \(self.socketPath, privacy: .public)")
    }

    /// Whether something already answers on the socket.
    static func answers(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    // MARK: Peers

    private func accept(_ listenFD: Int32) {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            // Only the user who runs the daemon.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            lastPeerID += 1
            let peer = Peer(id: lastPeerID, fd: fd, queue: queue)
            peers[peer.id] = peer
            idleExit?.cancel()
            peer.start(onBytes: { [weak self, weak peer] bytes in
                guard let self, let peer else { return }
                self.received(bytes, from: peer)
            }, onClose: { [weak self, weak peer] in
                guard let self, let peer else { return }
                self.gone(peer)
            })
        }
    }

    private func gone(_ peer: Peer) {
        peers[peer.id] = nil
        for pane in peer.panes { sessions[pane]?.peers.remove(peer.id) }
        scheduleIdleExit()
    }

    private func received(_ bytes: Data, from peer: Peer) {
        let frames: [(kind: UInt8, payload: Data)]
        do {
            frames = try peer.reader.read(bytes)
        } catch {
            peer.close()
            return gone(peer)
        }
        for frame in frames {
            guard let kind = SessionProtocol.Kind(rawValue: frame.kind) else { continue }
            handle(kind, frame.payload, from: peer)
            if peer.closed { return gone(peer) }
        }
    }

    private func handle(_ kind: SessionProtocol.Kind, _ payload: Data, from peer: Peer) {
        if !peer.introduced {
            guard kind == .hello, SessionProtocol.decode(Hello.self, payload) != nil else { return peer.close() }
            peer.introduced = true
            peer.send(SessionProtocol.frame(.welcome, Welcome(pid: getpid(), build: build)))
            return
        }
        switch kind {
        case .open:
            guard let open = SessionProtocol.decode(Open.self, payload) else { return }
            self.open(open, for: peer)
        case .input:
            guard let (pane, bytes) = SessionProtocol.paneBytes(payload) else { return }
            sessions[pane]?.write(bytes)
        case .resize:
            guard let resize = SessionProtocol.decode(Resize.self, payload) else { return }
            sessions[resize.pane]?.resize(cols: resize.cols, rows: resize.rows, widthPx: resize.widthPx, heightPx: resize.heightPx)
        case .close:
            guard let ref = SessionProtocol.decode(PaneRef.self, payload) else { return }
            peer.panes.remove(ref.pane)
            sessions[ref.pane]?.hangUp()
        case .detach:
            guard let ref = SessionProtocol.decode(PaneRef.self, payload) else { return }
            peer.panes.remove(ref.pane)
            sessions[ref.pane]?.peers.remove(peer.id)
        case .list:
            let list = SessionList(sessions: sessions.values.map { .init(pane: $0.pane, pid: $0.pid, cols: $0.cols, rows: $0.rows) })
            peer.send(SessionProtocol.frame(.sessions, list))
        default:
            break
        }
    }

    // MARK: Sessions

    /// Attaches the peer to the pane's program, starting it unless it runs already; then its
    /// output goes to the peer.
    private func open(_ open: Open, for peer: Peer) {
        if let session = sessions[open.pane] {
            // Back after the app quit: at the app's grid, then the snapshot of it.
            if session.cols != open.cols || session.rows != open.rows {
                session.resize(cols: open.cols, rows: open.rows, widthPx: open.widthPx, heightPx: open.heightPx)
            }
            session.refreshStatus(checkingMode: true)
            let snapshot = session.terminal.snapshot(scrollback: open.scrollback)
            session.peers.insert(peer.id)
            peer.panes.insert(open.pane)
            peer.send(SessionProtocol.frame(.opened, Opened(pane: open.pane, pid: session.pid, reattached: true, snapshot: snapshot,
                                                            cols: session.cols, rows: session.rows, status: session.status)))
            return
        }
        do {
            let session = try Session(open, queue: queue)
            session.send = { [weak self] peers, frame in
                guard let self else { return }
                for id in peers { self.peers[id]?.send(frame) }
            }
            session.onEnd = { [weak self] session in
                guard let self else { return }
                if self.sessions[session.pane] === session { self.sessions[session.pane] = nil }
                for peer in self.peers.values { peer.panes.remove(session.pane) }
                self.scheduleIdleExit()
            }
            sessions[open.pane] = session
            session.peers.insert(peer.id)
            peer.panes.insert(open.pane)
            peer.send(SessionProtocol.frame(.opened, Opened(pane: open.pane, pid: session.pid, reattached: false, snapshot: nil,
                                                            cols: session.cols, rows: session.rows, status: session.status)))
            session.start()
            Self.log.info("started \(open.args.first ?? "", privacy: .public) for \(open.pane.uuidString, privacy: .public)")
        } catch {
            peer.send(SessionProtocol.frame(.failed, SessionFailure(pane: open.pane, message: "\(error)")))
        }
    }

    private func scheduleIdleExit() {
        idleExit?.cancel()
        guard sessions.isEmpty, peers.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessions.isEmpty, self.peers.isEmpty else { return }
            Self.log.info("nothing to run: exiting")
            unlink(self.socketPath)
            exit(0)
        }
        idleExit = work
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: work)
    }
}
