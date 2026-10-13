import AgentHooks
import Darwin
import XCTest

final class HookListenerTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("hooks.sock").path }
    private let pane = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let deliveries = DispatchQueue(label: "HookListenerTests")
    private let received = Received()

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [HookMessage] = []
        func add(_ m: HookMessage) { lock.withLock { messages.append(m) } }
        var all: [HookMessage] { lock.withLock { messages } }
    }

    override func setUpWithError() throws {
        // Short: a socket's path has to fit in 104 bytes.
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func listener(allowsPeer: @escaping @Sendable (uid_t) -> Bool = { $0 == getuid() }) -> HookListener {
        let received = received
        return HookListener(path: path, deliveryQueue: deliveries, allowsPeer: allowsPeer) { received.add($0) }
    }

    /// Connects, writes, hangs up.
    private func send(_ data: Data) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    private func line(_ event: String) -> Data {
        Data(#"{"pane":"\#(pane.uuidString)","event":"\#(event)","payload":{}}"#.utf8) + Data("\n".utf8)
    }

    /// Waits for the listener's queue and the delivery queue to settle.
    private func settle() {
        Thread.sleep(forTimeInterval: 0.2)
        deliveries.sync {}
    }

    func testDeliversMessagesAndDropsMalformedLines() throws {
        let l = listener()
        try l.start()
        defer { l.stop() }
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        send(line("Stop") + Data("not json\n{\"pane\":\"x\"}\n".utf8) + line("PreToolUse") + Data(#"{"pane":"\#(pane.uuidString)","event":"Notification"}"#.utf8))
        settle()
        // The last line, without its newline, counts too.
        XCTAssertEqual(received.all.map(\.event), [.stop, .preToolUse, .notification])
    }

    func testAnOverlongLineIsNotAMessage() throws {
        let l = listener()
        try l.start()
        defer { l.stop() }
        var long = Data(#"{"pane":"\#(pane.uuidString)","event":"Stop","payload":{"cwd":""#.utf8)
        long += Data(repeating: UInt8(ascii: "a"), count: HookListener.maxLine)
        long += Data("\"}}\n".utf8)
        send(long)
        send(line("Stop"))
        settle()
        XCTAssertEqual(received.all.map(\.event), [.stop])
    }

    func testAPeerNotAllowedIsHungUpOn() throws {
        let l = listener(allowsPeer: { _ in false })
        try l.start()
        defer { l.stop() }
        send(line("Stop"))
        settle()
        XCTAssertTrue(received.all.isEmpty)
    }

    func testDoesNotTakeASocketAnotherListenerUses() throws {
        let first = listener()
        try first.start()
        defer { first.stop() }
        XCTAssertThrowsError(try listener().start()) { XCTAssertEqual($0 as? HookListener.Failure, .inUse) }
        send(line("Stop"))
        settle()
        XCTAssertEqual(received.all.count, 1)
    }

    func testReplacesAStaleSocket() throws {
        // A socket file nobody listens on (left by a crash).
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let l = listener()
        try l.start()
        defer { l.stop() }
        send(line("Stop"))
        settle()
        XCTAssertEqual(received.all.count, 1)
    }

    /// Another app took the path since (the file was removed, and it made its own): stopping
    /// leaves that app's socket.
    func testStopLeavesASocketThatIsNoLongerItsOwn() throws {
        let first = listener()
        try first.start()
        unlink(path)
        let second = listener()
        try second.start()
        first.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        second.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
