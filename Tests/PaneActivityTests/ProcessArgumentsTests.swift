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

    func testAProcessThatIsGoneReadsNil() {
        XCTAssertNil(ProcessArguments.read(pid: 999_999))
    }
}
