import Foundation
import PaneActivity
import XCTest

final class ProcessArgumentsTests: XCTestCase {
    func testReadsAnotherProcesssPathAndArguments() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate() }
        let info = try XCTUnwrap(ProcessArguments.read(pid: process.processIdentifier))
        XCTAssertEqual(info.executable, "/bin/sleep")
        XCTAssertEqual(info.arguments, ["/bin/sleep", "5"])
    }

    func testReadsAProcesssWorkingDirectory() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/usr/bin")
        try process.run()
        defer { process.terminate() }
        XCTAssertEqual(ProcessArguments.workingDirectory(pid: process.processIdentifier), "/usr/bin")
        XCTAssertNil(ProcessArguments.workingDirectory(pid: 999_999))
    }

    func testAProcessThatIsGoneReadsNil() {
        XCTAssertNil(ProcessArguments.read(pid: 999_999))
    }
}

final class ProcessArgumentsParsingTests: XCTestCase {
    private func bytes(argc: Int32, _ rest: String) -> [UInt8] {
        withUnsafeBytes(of: argc) { Array($0) } + Array(rest.utf8)
    }

    func testParsesPathAndArguments() {
        let parsed = ProcessArguments.parse(bytes(argc: 2, "/bin/sleep\0\0\0\0sleep\05\0PATH=/bin\0"))
        XCTAssertEqual(parsed, ProcessArguments(executable: "/bin/sleep", arguments: ["sleep", "5"]))
    }

    /// A program that rewrote its argv (node's `process.title`) leaves NULs where its arguments
    /// were: they are empty, and the environment after them is not read as arguments.
    func testOverwrittenArgumentsAreEmptyNotTheEnvironment() {
        let parsed = ProcessArguments.parse(bytes(argc: 3, "/opt/homebrew/bin/node\0\0claude\0\0\0\0\0\0\0\0OSLogRateLimit=64\0"))
        XCTAssertEqual(parsed?.arguments, ["claude", "", ""])
    }

    func testGarbageReadsNil() {
        XCTAssertNil(ProcessArguments.parse([1, 0]))
    }
}
