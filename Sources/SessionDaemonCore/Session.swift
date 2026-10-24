import CPtySpawn
import Foundation
import SessionProtocol

/// One pane's program on a pty the daemon owns, and the terminal its output builds
/// (`VirtualTerminal`). On the daemon's queue. It runs whether or not the app is there; the peers
/// attached to it get its output, its status and its exit.
final class Session {
    let pane: UUID
    let pid: pid_t
    private let master: Int32
    private let ptyName: String
    private let started = Date()
    private let queue: DispatchQueue
    let terminal: VirtualTerminal
    private(set) var cols: Int
    private(set) var rows: Int
    /// The peers its output goes to.
    var peers: Set<Int> = []
    private(set) var status: Status
    private var modeChecked = Date.distantPast
    private var readSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?
    private var writeSource: DispatchSourceWrite?
    private var writing = false
    private var input = Data()
    private(set) var ended = false

    /// What the session tells its peers: a frame for each of them (by peer id).
    var send: ((_ peers: Set<Int>, _ frame: Data) -> Void)?
    /// Called once when the program has exited and the session is done.
    var onEnd: ((Session) -> Void)?

    enum Failure: Error, CustomStringConvertible {
        case spawn(Int32)
        case noTerminal
        case badCommand

        var description: String {
            switch self {
            case .spawn(let code): "could not start the program: \(String(cString: strerror(code)))"
            case .noTerminal: "could not make a terminal"
            case .badCommand: "the command is empty or not an absolute path"
            }
        }
    }

    init(_ open: Open, queue: DispatchQueue) throws {
        guard let path = open.args.first, path.hasPrefix("/") else { throw Failure.badCommand }
        guard let terminal = VirtualTerminal(cols: open.cols, rows: open.rows) else { throw Failure.noTerminal }
        self.pane = open.pane
        self.queue = queue
        self.terminal = terminal
        let cols = max(open.cols, 1), rows = max(open.rows, 1)
        self.cols = cols
        self.rows = rows
        terminal.resize(cols: cols, rows: rows, cellWidth: open.widthPx / cols, cellHeight: open.heightPx / rows)

        // C strings for the child, made before the fork (the child may not allocate).
        let argv = open.args.map { strdup($0) } + [nil]
        let envp = open.env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var master: Int32 = -1
        let pid = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                promptty_pty_spawn(args.baseAddress, env.baseAddress, open.cwd,
                                   UInt16(clamping: cols), UInt16(clamping: rows),
                                   UInt16(clamping: open.widthPx), UInt16(clamping: open.heightPx), &master)
            }
        }
        guard pid > 0 else { throw Failure.spawn(errno) }
        self.pid = pid
        self.master = master
        var name = [CChar](repeating: 0, count: 128)
        ptyName = promptty_pty_name(master, &name, name.count) == 0
            ? String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        status = Status(pane: open.pane, foreground: nil, password: false)
    }

    /// Starts reading its output and watching for its exit.
    func start() {
        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { [weak self] in self?.readOutput() }
        readSource = read
        read.resume()
        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        process.setEventHandler { [weak self] in self?.reap() }
        processSource = process
        process.resume()
        // It may have exited before the source was watching.
        reap()
    }

    // MARK: Output

    private func readOutput() {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while !ended {
            let count = Darwin.read(master, &buffer, buffer.count)
            if count > 0 {
                let chunk = buffer.withUnsafeBytes { UnsafeRawBufferPointer(rebasing: $0[0..<count]) }
                terminal.write(chunk)
                // The process in front first: the app reads it when the output tells it a
                // prompt is ready.
                refreshStatus(checkingMode: false)
                if !peers.isEmpty {
                    send?(peers, SessionProtocol.frame(.output, pane: pane, bytes: Data(buffer[0..<count])))
                }
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                return
            } else {
                // EOF or EIO: the slave side closed. The exit follows (`reap`).
                readSource?.cancel()
                readSource = nil
                return
            }
        }
    }

    /// The process in front and (at most every 100 ms, unless asked) whether it reads a password;
    /// peers are told when either changed.
    func refreshStatus(checkingMode: Bool) {
        guard !ended else { return }
        let foreground = tcgetpgrp(master)
        var next = status
        next.foreground = foreground > 0 ? foreground : nil
        let now = Date()
        if checkingMode || now.timeIntervalSince(modeChecked) > 0.1 {
            modeChecked = now
            next.password = readsPassword()
        }
        guard next != status else { return }
        status = next
        if !peers.isEmpty { send?(peers, SessionProtocol.frame(.status, next)) }
    }

    private func readsPassword() -> Bool {
        guard !ptyName.isEmpty else { return false }
        let fd = open(ptyName, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var mode = termios()
        guard tcgetattr(fd, &mode) == 0 else { return false }
        return mode.c_lflag & tcflag_t(ICANON) != 0 && mode.c_lflag & tcflag_t(ECHO) == 0
    }

    // MARK: Input

    func write(_ bytes: Data) {
        guard !ended, !bytes.isEmpty else { return }
        input.append(bytes)
        flushInput()
    }

    private func flushInput() {
        while !input.isEmpty {
            let written = input.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if written > 0 {
                input.removeFirst(written)
            } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                waitForRoom()
                return
            } else {
                input = Data()
                return
            }
        }
        input = Data()
    }

    private func waitForRoom() {
        guard !writing else { return }
        writing = true
        if let writeSource {
            writeSource.resume()
            return
        }
        let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.writeSource?.suspend()
            self.writing = false
            self.flushInput()
        }
        writeSource = source
        source.resume()
    }

    // MARK: Size

    func resize(cols: Int, rows: Int, widthPx: Int, heightPx: Int) {
        guard !ended else { return }
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        var size = winsize(ws_row: UInt16(clamping: self.rows), ws_col: UInt16(clamping: self.cols),
                           ws_xpixel: UInt16(clamping: widthPx), ws_ypixel: UInt16(clamping: heightPx))
        _ = ioctl(master, TIOCSWINSZ, &size)
        terminal.resize(cols: self.cols, rows: self.rows, cellWidth: widthPx / self.cols, cellHeight: heightPx / self.rows)
    }

    // MARK: Ending

    /// The pane closed in the app: its program's process group is hung up on, as closing a
    /// terminal does, and the session ends without telling anyone.
    func hangUp() {
        guard !ended else { return }
        peers = []
        killpg(pid, SIGHUP)
        end()
    }

    private func reap() {
        var code: Int32 = 0
        guard waitpid(pid, &code, WNOHANG) == pid else { return }
        // What it wrote last, before telling anyone it is gone.
        if readSource != nil { readOutput() }
        let exitCode: Int32 = (code & 0x7f) == 0 ? (code >> 8) & 0xff : 128 + (code & 0x7f)
        let runtime = UInt64(max(0, Date().timeIntervalSince(started) * 1000))
        if !peers.isEmpty {
            send?(peers, SessionProtocol.frame(.exited, Exited(pane: pane, code: exitCode, runtimeMs: runtime)))
        }
        end()
    }

    private func end() {
        guard !ended else { return }
        ended = true
        if let writeSource {
            if !writing { writeSource.resume() }
            writeSource.cancel()
        }
        let master = master
        if let readSource {
            readSource.setCancelHandler { Darwin.close(master) }
            readSource.cancel()
        } else {
            Darwin.close(master)
        }
        readSource = nil
        if let processSource {
            if waitpid(pid, nil, WNOHANG) == 0 {
                // Hung up on and still going: watched until it goes, so it is reaped.
                Self.reap(pid, watchedBy: processSource)
            } else {
                processSource.cancel()
            }
        }
        processSource = nil
        onEnd?(self)
    }

    /// Programs hung up on that haven't exited yet, by pid: their sources outlive their sessions.
    private nonisolated(unsafe) static var hungUp: [pid_t: DispatchSourceProcess] = [:]

    private static func reap(_ pid: pid_t, watchedBy source: DispatchSourceProcess) {
        hungUp[pid] = source
        source.setEventHandler {
            guard waitpid(pid, nil, WNOHANG) == pid else { return }
            hungUp.removeValue(forKey: pid)?.cancel()
        }
    }
}
