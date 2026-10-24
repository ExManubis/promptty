import AppKit
import GhosttyKit
import Synchronization
import XCTest
@testable import GhosttyBridge

private final class Collected: Sendable {
    private let state = Mutex((bytes: Data(), calls: 0))
    func add(_ data: Data) { state.withLock { $0.bytes.append(data); $0.calls += 1 } }
    var bytes: Data { state.withLock { $0.bytes } }
    var calls: Int { state.withLock { $0.calls } }
}

/// Called on libghostty's read thread, so not from inside the (main actor) test.
private let countingTap: ghostty_surface_output_tap_cb = { userdata, bytes, len in
    Unmanaged<Collected>.fromOpaque(userdata!).takeUnretainedValue().add(Data(bytes: bytes!, count: len))
}

final class TerminalOutputTests: XCTestCase {
    private func feed(_ output: TerminalOutput, _ chunk: [UInt8]) {
        chunk.withUnsafeBytes { output.receive($0) }
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    func testChunksReachEverySubscriberInOrderAndUnchanged() {
        let output = TerminalOutput()
        let a = Collected(), b = Collected()
        let subA = output.subscribe { a.add($0) }
        let subB = output.subscribe { b.add($0) }
        let chunks: [[UInt8]] = [Array("hi \u{1b}[1;31mred\u{1b}[0m\r\n".utf8), [0x00, 0xff, 0xc3], [0xa9, 0x0a]]
        // From another thread, as libghostty's read thread calls it.
        let done = expectation(description: "fed")
        DispatchQueue.global().async {
            for chunk in chunks { self.feed(output, chunk) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let expected = Data(chunks.joined())
        XCTAssertTrue(waitUntil { a.bytes.count == expected.count && b.bytes.count == expected.count })
        XCTAssertEqual(a.bytes, expected)
        XCTAssertEqual(b.bytes, expected)
        withExtendedLifetime((subA, subB)) {}
    }

    func testCancelledSubscriberGetsNothingMoreAndTheLastOneTurnsTheTapOff() {
        let changes = Mutex<[Bool]>([])
        let output = TerminalOutput { any in changes.withLock { $0.append(any) } }
        let collected = Collected()
        let sub = output.subscribe { collected.add($0) }
        feed(output, Array("one".utf8))
        XCTAssertTrue(waitUntil { collected.calls == 1 })
        sub.cancel()
        XCTAssertFalse(output.hasSubscribers)
        feed(output, Array("two".utf8))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(collected.bytes, Data("one".utf8))
        XCTAssertEqual(changes.withLock { $0 }, [true, false])
    }

    func testOutputWithoutSubscribersIsDropped() {
        let output = TerminalOutput()
        feed(output, Array("before".utf8))
        let collected = Collected()
        let sub = output.subscribe { collected.add($0) }
        feed(output, Array("after".utf8))
        XCTAssertTrue(waitUntil { collected.calls == 1 })
        XCTAssertEqual(collected.bytes, Data("after".utf8))
        withExtendedLifetime(sub) {}
    }

    /// A real surface running a script: what it prints reaches the tap byte for byte, and once the
    /// tap is off libghostty calls it no more.
    @MainActor
    func testSurfaceOutputReachesTheTapUnchanged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // No newline in the checked part: the pty turns \n into \r\n.
        let script = dir.appendingPathComponent("print.sh")
        try """
        #!/bin/sh
        printf 'tap-start \\033[1;31mred\\033[0m \\303\\251 \\033]0;title\\007tap-end'
        while :; do printf 'tick\\r'; sleep 0.05; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let config = dir.appendingPathComponent("terminal.conf")
        try "command = \(script.path)\nkeybind = clear\n".write(to: config, atomically: true, encoding: .utf8)

        let runtime = try GhosttyRuntime(configURL: config)
        let view = TerminalSurfaceView(runtime: runtime, configuration: .init(workingDirectory: dir.path))
        let collected = Collected()
        let subscription = view.output.subscribe { collected.add($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer {
            view.teardown()
            window.contentView = nil
        }
        XCTAssertTrue(view.outputTapSet)

        let expected = Data("tap-start \u{1b}[1;31mred\u{1b}[0m é \u{1b}]0;title\u{07}tap-end".utf8)
        XCTAssertTrue(waitUntil { collected.bytes.range(of: expected) != nil }, "got \(String(decoding: collected.bytes, as: UTF8.self).debugDescription)")

        subscription.cancel()
        XCTAssertFalse(view.outputTapSet)

        // libghostty's own side: a tap counting calls, then turned off while the script prints.
        let counted = Collected()
        let surface = try XCTUnwrap(view.surface)
        ghostty_surface_set_output_tap(surface, countingTap, Unmanaged.passUnretained(counted).toOpaque())
        XCTAssertTrue(waitUntil { counted.calls >= 3 })
        ghostty_surface_set_output_tap(surface, nil, nil)
        let calls = counted.calls
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(counted.calls, calls)
        XCTAssertTrue(String(decoding: counted.bytes, as: UTF8.self).contains("tick\r"))
    }
}
