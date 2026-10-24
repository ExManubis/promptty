import AppKit
import GhosttyKit
import Synchronization
import XCTest
@testable import GhosttyBridge

private final class Chunks: Sendable {
    private let state = Mutex<[TerminalOutput.Chunk]>([])
    func add(_ chunk: TerminalOutput.Chunk) { state.withLock { $0.append(chunk) } }
    var all: [TerminalOutput.Chunk] { state.withLock { $0 } }
    var bytes: Data { all.reduce(Data()) { $0 + $1.data } }
}

final class TerminalOutputNumberingTests: XCTestCase {
    private func feed(_ output: TerminalOutput, _ text: String) {
        Array(text.utf8).withUnsafeBytes { output.receive($0) }
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    func testChunksAreNumberedFromTheFirstSubscriberAndANewOneStartsANewStream() {
        let output = TerminalOutput()
        feed(output, "unseen")
        let chunks = Chunks()
        var subscription: TerminalOutput.Subscription? = output.subscribeNumbered { chunks.add($0) }
        let stream = output.position.stream
        XCTAssertEqual(output.position.offset, 0)
        feed(output, "one ")
        XCTAssertTrue(waitUntil { chunks.bytes.count == 4 })
        feed(output, "two")
        XCTAssertTrue(waitUntil { chunks.bytes.count == 7 })
        XCTAssertEqual(chunks.all.map(\.offset), [0, 4])
        XCTAssertEqual(Set(chunks.all.map(\.stream)), [stream])
        XCTAssertEqual(output.position, TerminalOutput.Position(stream: stream, offset: 7))

        subscription = nil
        _ = subscription
        let again = Chunks()
        let second = output.subscribeNumbered { again.add($0) }
        XCTAssertNotEqual(output.position.stream, stream)
        XCTAssertEqual(output.position.offset, 0)
        withExtendedLifetime(second) {}
    }
}

final class RemoteKeyMapTests: XCTestCase {
    func testCharactersArePressedAsTheUSKeyboardWould() {
        XCTAssertEqual(RemoteKeyMap.press(for: "a"), .init(keyCode: 0, mods: GHOSTTY_MODS_NONE, text: "a", unshifted: 97))
        XCTAssertEqual(RemoteKeyMap.press(for: "A"), .init(keyCode: 0, mods: GHOSTTY_MODS_SHIFT, text: "A", unshifted: 97))
        XCTAssertEqual(RemoteKeyMap.press(for: "?"), .init(keyCode: 44, mods: GHOSTTY_MODS_SHIFT, text: "?", unshifted: 47))
        XCTAssertEqual(RemoteKeyMap.press(for: " ")?.keyCode, 49)
        XCTAssertEqual(RemoteKeyMap.press(for: "é"), .init(keyCode: RemoteKeyMap.unidentified, mods: GHOSTTY_MODS_NONE, text: "é", unshifted: 233))
    }

    func testControlCharactersAndNamedKeys() {
        XCTAssertEqual(RemoteKeyMap.press(for: "\r")?.keyCode, 36)
        XCTAssertEqual(RemoteKeyMap.press(for: "\n")?.keyCode, 36)
        XCTAssertEqual(RemoteKeyMap.press(for: "\t")?.keyCode, 48)
        XCTAssertEqual(RemoteKeyMap.press(for: "\u{7f}")?.keyCode, 51)
        XCTAssertEqual(RemoteKeyMap.press(for: "\u{1b}")?.keyCode, 53)
        // ^C: Control and c, its text the letter.
        XCTAssertEqual(RemoteKeyMap.press(for: "\u{3}"), .init(keyCode: 8, mods: GHOSTTY_MODS_CTRL, text: "c", unshifted: 99))
        XCTAssertEqual(RemoteKeyMap.press(named: "up"), .init(keyCode: 126, mods: GHOSTTY_MODS_NONE, text: nil, unshifted: 0))
        XCTAssertEqual(RemoteKeyMap.press(named: "f12")?.keyCode, 111)
        XCTAssertNil(RemoteKeyMap.press(named: "hyper"))
        XCTAssertNil(RemoteKeyMap.press(for: "\u{0}"))
    }
}

/// Real terminals: a snapshot taken while a program prints, and the output after it, rebuild the
/// same terminal in a second one; a controlled grid sizes the terminal whatever its view's size.
@MainActor
final class TerminalSnapshotTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    private func terminal(running script: String, in dir: URL, name: String) throws -> (TerminalSurfaceView, NSWindow) {
        let file = dir.appendingPathComponent("\(name).sh")
        try ("#!/bin/sh\n" + script).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let config = dir.appendingPathComponent("\(name).conf")
        try "command = \(file.path)\nkeybind = clear\nscrollback-limit = 10000000\n".write(to: config, atomically: true, encoding: .utf8)
        let runtime = try GhosttyRuntime(configURL: config)
        let view = TerminalSurfaceView(runtime: runtime, configuration: .init(workingDirectory: dir.path))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        return (view, window)
    }

    func testASnapshotAndTheOutputAfterItRebuildTheTerminal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let done = dir.appendingPathComponent("done")
        // Colored lines long enough to wrap, then a full-screen program on the alternate screen
        // (vim-like), back to the shell's screen, and a prompt.
        let (source, sourceWindow) = try terminal(running: """
            i=0
            while [ $i -lt 400 ]; do
              printf '\\033[3%dmline %d\\033[0m and some text long enough to wrap past the edge of the terminal \\303\\251\\n' $((i % 7)) $i
              i=$((i+1)); sleep 0.002
            done
            printf '\\033[?1049h\\033[?2004h\\033[2J\\033[H~ alt screen\\r\\n~ \\033[1mbold\\033[0m\\033[5;10Hcursor'
            sleep 0.3
            printf '\\033[?1049l\\033[?2004lback on the shell\\r\\n$ '
            touch \(done.path)
            sleep 1000
            """, in: dir, name: "source")
        defer { source.teardown(); sourceWindow.contentView = nil }

        let chunks = Chunks()
        let subscription = source.output.subscribeNumbered { chunks.add($0) }
        XCTAssertTrue(waitUntil { String(decoding: chunks.bytes, as: UTF8.self).contains("line 60\u{1b}") })
        let snapshot = try XCTUnwrap(source.vtSnapshot(scrollback: 100_000))
        XCTAssertEqual(snapshot.grid, source.grid)
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: done.path) })
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        withExtendedLifetime(subscription) {}

        // The chunks are numbered without a gap, and the snapshot's position is among them.
        let all = chunks.all
        for (a, b) in zip(all, all.dropFirst()) {
            XCTAssertEqual(a.offset + a.data.count, b.offset)
            XCTAssertEqual(a.stream, b.stream)
        }
        let first = try XCTUnwrap(all.first)
        XCTAssertEqual(snapshot.position.stream, first.stream)
        XCTAssertGreaterThanOrEqual(snapshot.position.offset, first.offset)
        let after = chunks.bytes.dropFirst(snapshot.position.offset - first.offset)

        let replay = dir.appendingPathComponent("replay")
        try (snapshot.vt + after).write(to: replay)
        let copied = dir.appendingPathComponent("copied")
        let (copy, copyWindow) = try terminal(running: "stty -opost -echo\ncat \(replay.path)\ntouch \(copied.path)\nsleep 1000\n", in: dir, name: "copy")
        defer { copy.teardown(); copyWindow.contentView = nil }
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: copied.path) })
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(copy.grid, source.grid)
        XCTAssertEqual(copy.activeScreenText(), source.activeScreenText())
        XCTAssertEqual(copy.allText(styled: true), source.allText(styled: true))
        XCTAssertTrue(source.activeScreenText()?.contains("back on the shell") == true)
    }

    func testAControlledGridSizesTheTerminalAndLettingGoRestoresIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (view, window) = try terminal(running: "sleep 1000\n", in: dir, name: "grid")
        defer { view.teardown(); window.contentView = nil }
        let mac = try XCTUnwrap(view.grid)

        view.gridOverride = TerminalGrid(cols: 40, rows: 12)
        XCTAssertEqual(view.grid, TerminalGrid(cols: 40, rows: 12))
        // Bigger than the view: the terminal has it all the same (drawn cut off).
        view.gridOverride = TerminalGrid(cols: mac.cols + 30, rows: mac.rows + 5)
        XCTAssertEqual(view.grid, TerminalGrid(cols: mac.cols + 30, rows: mac.rows + 5))
        view.gridOverride = nil
        XCTAssertEqual(view.grid, mac)
    }
}
