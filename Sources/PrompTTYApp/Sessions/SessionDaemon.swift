import AgentHooks
import Foundation
import GhosttyBridge
import os
import SessionProtocol
import WorkspaceModel

/// The app's connection to prompttyd (PTY-77), which runs the panes' programs on ptys of its own
/// so they keep running when the app quits. With Settings › Tabs › Keep programs running on, a
/// new pane's surface is hosted: libghostty works out the program (`ExecPlan`), the daemon runs
/// it, its output feeds the surface and the surface's writes go back. A pane the daemon still runs
/// from before the app quit is rebuilt from the daemon's snapshot of it and goes on.
///
/// Frames are written on `queue` and read there; output goes straight to the surface from it
/// (`SurfaceHostLink.feed` takes any thread), the rest to the main actor.
final class SessionDaemon: @unchecked Sendable {
    static let shared = SessionDaemon()

    private let queue = DispatchQueue(label: "dev.promptty.sessions", qos: .userInteractive)
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var fd: Int32 = -1
    private var panes: [UUID: HostedPane] = [:]
    /// On `queue`.
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var waitingForRoom = false
    private var pending = Data()
    private var reader = SessionFrameReader()
    private static let log = Logger(subsystem: "dev.promptty.PrompTTY2", category: "sessions")

    /// Whether new panes are hosted: the setting is on and the daemon answered.
    var isAvailable: Bool { lock.withLock { fd >= 0 } }

    /// The socket, beside the app's others.
    static let socketPath = HookSocket.path(named: "prompttyd", dataFolder: AppPaths.support.path, temporaryDirectory: NSTemporaryDirectory())

    /// The daemon in the app bundle.
    static var executable: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/prompttyd")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: Starting

    /// At launch, before any surface exists. On: connects, starting the daemon if it isn't
    /// running. Off: a daemon left from when it was on ends the programs it runs, which nothing
    /// will show again.
    @MainActor
    func start(enabled: Bool) {
        guard enabled else { return closeLeftovers() }
        guard let socket = connect(startingIfNeeded: true) else {
            return Self.log.error("prompttyd: not reachable; panes run in the app")
        }
        guard handshake(socket) else {
            Darwin.close(socket)
            return Self.log.error("prompttyd: a different version answers; panes run in the app")
        }
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        lock.withLock { fd = socket }
        queue.async { self.startReading(socket) }
        Self.log.info("prompttyd: connected")
    }

    /// Ends what a daemon left running while the setting was on.
    @MainActor
    private func closeLeftovers() {
        guard let socket = connect(startingIfNeeded: false) else { return }
        defer { Darwin.close(socket) }
        guard handshake(socket), Self.writeAll(socket, SessionProtocol.frame(.list, Data("{}".utf8))),
              let list = Self.readFrame(socket, kind: .sessions, timeout: 1).flatMap({ SessionProtocol.decode(SessionList.self, $0) }) else { return }
        for session in list.sessions {
            _ = Self.writeAll(socket, SessionProtocol.frame(.close, PaneRef(pane: session.pane)))
        }
    }

    /// A connected socket, after starting the daemon if nothing answered and it may.
    private func connect(startingIfNeeded: Bool) -> Int32? {
        if let socket = Self.connectSocket(Self.socketPath) { return socket }
        guard startingIfNeeded, let executable = Self.executable else { return nil }
        guard Self.launch(executable, socket: Self.socketPath) else { return nil }
        // It listens within a few milliseconds.
        for _ in 0..<100 {
            usleep(20_000)
            if let socket = Self.connectSocket(Self.socketPath) { return socket }
        }
        return nil
    }

    /// Starts the daemon in a session of its own, so the app's going doesn't end it.
    private static func launch(_ executable: URL, socket: String) -> Bool {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let arguments = [executable.path, "--socket", socket]
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        if result != 0 { log.error("prompttyd: could not start it: \(String(cString: strerror(result)), privacy: .public)") }
        return result == 0
    }

    private static func connectSocket(_ path: String) -> Int32? {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socket)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            Darwin.close(socket)
            return nil
        }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
        return socket
    }

    /// Hello, and a welcome of this version, within a second (the socket still blocks).
    private func handshake(_ socket: Int32) -> Bool {
        guard Self.writeAll(socket, SessionProtocol.frame(.hello, Hello(client: "PrompTTY"))),
              let payload = Self.readFrame(socket, kind: .welcome, timeout: 1),
              let welcome = SessionProtocol.decode(Welcome.self, payload) else { return false }
        return welcome.version == SessionProtocol.version
    }

    private static func writeAll(_ socket: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(socket, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// The next frame of `kind` on a blocking socket, waiting at most `timeout` seconds.
    private static func readFrame(_ socket: Int32, kind: SessionProtocol.Kind, timeout: TimeInterval) -> Data? {
        var wait = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var reader = SessionFrameReader()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(socket, &buffer, buffer.count)
            guard count > 0, let frames = try? reader.read(Data(buffer[0..<count])) else { return nil }
            if let frame = frames.first(where: { $0.kind == kind.rawValue }) { return frame.payload }
        }
    }

    // MARK: Panes

    /// A hosted surface for `pane`: its program runs in the daemon once the surface has its plan
    /// and its grid, or the daemon's from before goes on in it.
    @MainActor
    func host(_ view: TerminalSurfaceView, for pane: PaneID, onReattached: @escaping @MainActor () -> Void) {
        guard let link = view.hostLink else { return }
        let id = pane.rawValue
        let hosted = HostedPane(pane: id, daemon: self, view: view, onReattached: onReattached)
        lock.withLock { panes[id] = hosted }
        link.connect(write: { [weak hosted] bytes in hosted?.written(bytes) },
                     resize: { [weak hosted] cols, rows, width, height in hosted?.resized(cols: cols, rows: rows, widthPx: width, heightPx: height) })
        view.onHosted = { [weak hosted] plan in
            guard let plan else {
                // libghostty could not say what to run: nothing will.
                link.feed(Data("PrompTTY: could not work out the shell to start.\r\n".utf8))
                return
            }
            hosted?.planned(plan)
        }
        // The pane closed (not the app quitting): the daemon hangs up on its program.
        view.onHostedTeardown = { [weak self] in self?.hangUp(id) }
    }

    private func hangUp(_ pane: UUID) {
        let quitting = lock.withLock { () -> Bool in
            panes.removeValue(forKey: pane)
            return terminating
        }
        // AppKit closes the windows as the app quits: those programs keep running.
        guard !quitting else { return }
        send(SessionProtocol.frame(.close, PaneRef(pane: pane)))
    }

    /// Guarded by `lock`: the app is quitting.
    private var terminating = false

    /// The app is quitting: panes torn down from now on leave their programs running.
    func appTerminating() {
        lock.withLock { terminating = true }
    }

    /// Programs the daemon runs for panes the app no longer has (closed while it wasn't
    /// running, or not reopened) are ended. After launch, once the windows are back.
    func closeOrphans(keeping panes: Set<UUID>) {
        lock.withLock { orphanFilter = panes }
        send(SessionProtocol.frame(.list, Data("{}".utf8)))
    }

    /// Guarded by `lock`: the panes kept when the next session list comes.
    private var orphanFilter: Set<UUID>?

    // MARK: The connection

    /// Queues a frame; from any thread, in order.
    func send(_ frame: Data) {
        queue.async { [self] in
            guard lock.withLock({ fd }) >= 0 else { return }
            pending.append(frame)
            flush()
        }
    }

    /// On `queue`.
    private func flush() {
        let socket = lock.withLock { fd }
        while !pending.isEmpty, socket >= 0 {
            let written = pending.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
            if written > 0 {
                pending.removeFirst(written)
            } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                waitForRoom(socket)
                return
            } else {
                return disconnected()
            }
        }
        if pending.isEmpty { pending = Data() }
    }

    private func waitForRoom(_ socket: Int32) {
        guard !waitingForRoom else { return }
        waitingForRoom = true
        if let writeSource { return writeSource.resume() }
        let source = DispatchSource.makeWriteSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.writeSource?.suspend()
            self.waitingForRoom = false
            self.flush()
        }
        writeSource = source
        source.resume()
    }

    private func startReading(_ socket: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 256 << 10)
            while true {
                let count = read(socket, &buffer, buffer.count)
                if count > 0 {
                    guard let frames = try? self.reader.read(Data(buffer[0..<count])) else { return self.disconnected() }
                    for frame in frames { self.received(frame.kind, frame.payload) }
                } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                    return
                } else {
                    return self.disconnected()
                }
            }
        }
        readSource = source
        source.resume()
    }

    /// On `queue`.
    private func received(_ kind: UInt8, _ payload: Data) {
        switch SessionProtocol.Kind(rawValue: kind) {
        case .output:
            guard let (pane, bytes) = SessionProtocol.paneBytes(payload) else { return }
            lock.withLock { panes[pane] }?.output(bytes)
        case .opened:
            guard let opened = SessionProtocol.decode(Opened.self, payload) else { return }
            lock.withLock { panes[opened.pane] }?.opened(opened)
        case .status:
            guard let status = SessionProtocol.decode(Status.self, payload) else { return }
            lock.withLock { panes[status.pane] }?.status(status)
        case .exited:
            guard let exited = SessionProtocol.decode(Exited.self, payload) else { return }
            lock.withLock { panes.removeValue(forKey: exited.pane) }?.exited(code: exited.code, runtimeMs: exited.runtimeMs)
        case .failed:
            guard let failure = SessionProtocol.decode(SessionFailure.self, payload), let pane = failure.pane else { return }
            lock.withLock { panes.removeValue(forKey: pane) }?.failed(failure.message)
        case .sessions:
            guard let list = SessionProtocol.decode(SessionList.self, payload),
                  let keep = lock.withLock({ () -> Set<UUID>? in defer { orphanFilter = nil }; return orphanFilter }) else { return }
            for session in list.sessions where !keep.contains(session.pane) {
                Self.log.info("prompttyd: ending \(session.pane.uuidString, privacy: .public), a pane no window has")
                send(SessionProtocol.frame(.close, PaneRef(pane: session.pane)))
            }
        default:
            break
        }
    }

    /// On `queue`: the daemon went (it crashed, or was killed). Its programs went with it.
    private func disconnected() {
        let (socket, gone) = lock.withLock { () -> (Int32, [HostedPane]) in
            defer {
                fd = -1
                panes.removeAll()
            }
            return (fd, Array(panes.values))
        }
        guard socket >= 0 else { return }
        readSource?.cancel()
        readSource = nil
        if let writeSource {
            if !waitingForRoom { writeSource.resume() }
            writeSource.cancel()
        }
        writeSource = nil
        pending = Data()
        Darwin.close(socket)
        Self.log.error("prompttyd: the connection closed")
        for pane in gone { pane.failed("prompttyd went away") }
    }
}

/// One hosted pane: its open waits for the surface's plan and grid; keys typed before it went out
/// follow it.
final class HostedPane: @unchecked Sendable {
    let pane: UUID
    private unowned let daemon: SessionDaemon
    private weak var view: TerminalSurfaceView?
    private let link: SurfaceHostLink?
    private let onReattached: @MainActor () -> Void
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var plan: ExecPlan?
    private var grid: (cols: Int, rows: Int, widthPx: Int, heightPx: Int)?
    private var openSent = false
    private var early: [Data] = []

    @MainActor
    init(pane: UUID, daemon: SessionDaemon, view: TerminalSurfaceView, onReattached: @escaping @MainActor () -> Void) {
        self.pane = pane
        self.daemon = daemon
        self.view = view
        link = view.hostLink
        self.onReattached = onReattached
    }

    func planned(_ plan: ExecPlan) {
        let open = lock.withLock { () -> Open? in
            self.plan = plan
            return takeOpen()
        }
        if let open { sendOpen(open) }
    }

    /// On the IO thread: the surface's grid.
    func resized(cols: Int, rows: Int, widthPx: Int, heightPx: Int) {
        let (open, sent) = lock.withLock { () -> (Open?, Bool) in
            grid = (cols, rows, widthPx, heightPx)
            return (takeOpen(), openSent)
        }
        if let open { return sendOpen(open) }
        if sent { daemon.send(SessionProtocol.frame(.resize, Resize(pane: pane, cols: cols, rows: rows, widthPx: widthPx, heightPx: heightPx))) }
    }

    /// On the IO thread: what the terminal writes for the program.
    func written(_ bytes: Data) {
        let sent = lock.withLock { () -> Bool in
            if !openSent { early.append(bytes) }
            return openSent
        }
        if sent { daemon.send(SessionProtocol.frame(.input, pane: pane, bytes: bytes)) }
    }

    /// Under `lock`: the open, once there is a plan and a grid and it hasn't gone.
    private func takeOpen() -> Open? {
        guard !openSent, let plan, let grid else { return nil }
        openSent = true
        return Open(pane: pane, args: plan.args, env: plan.env, cwd: plan.cwd, cols: grid.cols, rows: grid.rows,
                    widthPx: grid.widthPx, heightPx: grid.heightPx)
    }

    private func sendOpen(_ open: Open) {
        daemon.send(SessionProtocol.frame(.open, open))
        let typed = lock.withLock { () -> [Data] in defer { early = [] }; return early }
        for bytes in typed { daemon.send(SessionProtocol.frame(.input, pane: pane, bytes: bytes)) }
    }

    // From the daemon, on its queue.

    func opened(_ opened: Opened) {
        // Back from before the app quit: the terminal as it is now, then what follows.
        if opened.reattached, let snapshot = opened.snapshot { link?.feed(snapshot) }
        status(opened.status)
        guard opened.reattached else { return }
        DispatchQueue.main.async { [onReattached] in MainActor.assumeIsolated { onReattached() } }
    }

    func output(_ bytes: Data) { link?.feed(bytes) }

    func status(_ status: Status) {
        DispatchQueue.main.async { [weak view] in
            MainActor.assumeIsolated {
                view?.hostForegroundPID = status.foreground.map(Int.init)
                view?.hostReadsPassword = status.password
            }
        }
    }

    func exited(code: Int32, runtimeMs: UInt64) {
        DispatchQueue.main.async { [weak view] in
            MainActor.assumeIsolated { view?.hostExited(code: code, runtimeMs: runtimeMs) }
        }
    }

    func failed(_ message: String) {
        link?.feed(Data("\r\nPrompTTY: \(message).\r\n".utf8))
        exited(code: 1, runtimeMs: 0)
    }
}
