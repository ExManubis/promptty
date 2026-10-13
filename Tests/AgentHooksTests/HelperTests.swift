import AgentHooks
import Darwin
import XCTest

/// Runs the built `promptty-hook` against a socket of the test's own.
final class HelperTests: XCTestCase {
    private var directory: URL!
    private var socketPath: String { HookSocket.path(dataFolder: directory.path, temporaryDirectory: NSTemporaryDirectory()) }
    private let pane = UUID()

    private var helper: URL {
        // The test bundle and the helper are built into the same products folder.
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("promptty-hook")
    }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ph-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "promptty-hook is not built")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Listens on the socket; returns its descriptor.
    private func listen() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 4), 0)
        return fd
    }

    /// Reads one connection to its end.
    private func receive(on fd: Int32) -> Data {
        let client = accept(fd, nil, nil)
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    /// Runs the helper; returns its exit status, its output and how long it took.
    private func run(_ arguments: [String], input: String?, environment: [String: String]) throws -> (status: Int32, output: Data, seconds: TimeInterval) {
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        let start = Date()
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus, stdout.fileHandleForReading.readDataToEndOfFile(), Date().timeIntervalSince(start))
    }

    private var paneEnvironment: [String: String] { HookEnvironment.variables(pane: pane, socket: socketPath) }

    func testSendsTheHookToTheApp() throws {
        let fd = try listen()
        defer { close(fd) }
        let result = try run(["Notification"], input: #"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","session_id":"x"}"#,
                             environment: paneEnvironment)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertLessThan(result.seconds, 0.5)
        let message = try XCTUnwrap(HookMessage.parse(receive(on: fd).dropLast()))
        XCTAssertEqual(message, HookMessage(pane: pane, event: .notification,
                                            payload: HookPayload(sessionID: "x", hookEventName: "Notification", message: "Claude needs your permission to use Bash")))
    }

    func testCodexNotify() throws {
        let fd = try listen()
        defer { close(fd) }
        let result = try run([#"{"type":"agent-turn-complete","turn-id":"1"}"#], input: nil, environment: paneEnvironment)
        XCTAssertEqual(result.status, 0)
        let message = try XCTUnwrap(HookMessage.parse(receive(on: fd).dropLast()))
        XCTAssertEqual(message.event, .codexNotify)
        XCTAssertEqual(message.payload.type, "agent-turn-complete")
    }

    func testOutsidePrompTTYDoesNothing() throws {
        let result = try run(["Stop"], input: "{}", environment: [:])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.isEmpty)
    }

    func testNoAppListeningIsNoError() throws {
        let result = try run(["Stop"], input: "{}", environment: paneEnvironment)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.isEmpty)
    }

    /// Standard input never closed: the helper gives up rather than hold up the agent.
    func testNeverBlocksTheAgent() throws {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["Stop"]
        process.environment = paneEnvironment
        let stdin = Pipe()
        process.standardInput = stdin
        let start = Date()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        try stdin.fileHandleForWriting.close()
    }
}
