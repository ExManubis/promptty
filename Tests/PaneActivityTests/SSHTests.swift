import XCTest
@testable import PaneActivity

final class SSHTests: XCTestCase {
    func testDestinationSkipsOptionsAndTheirValues() {
        XCTAssertEqual(SSHCommand.destination(arguments: ["ssh", "box"]), "box")
        XCTAssertEqual(SSHCommand.destination(arguments: ["ssh", "-p", "2222", "-i", "~/.ssh/k", "me@box", "uptime"]), "me@box")
        XCTAssertEqual(SSHCommand.destination(arguments: ["ssh", "-tA", "box"]), "box")
        XCTAssertEqual(SSHCommand.destination(arguments: ["ssh", "-p2222", "box"]), "box")
        XCTAssertEqual(SSHCommand.destination(arguments: ["ssh", "-l", "root", "box"]), "root@box")
        XCTAssertEqual(SSHCommand.destination(arguments: ["ssh", "ssh://me@box:2200"]), "me@box")
        XCTAssertEqual(SSHCommand.destination(arguments: ["mosh", "--ssh=ssh -p 2", "box"]), "box")
        XCTAssertNil(SSHCommand.destination(arguments: ["ssh", "-V"]))
    }

    func testConfigHostsSkipPatternsAndFollowIncludes() {
        let text = """
        # mine
        Host devbox prod-1
          HostName 10.0.0.1
        Host *.internal !bad
        Host=staging
        Include config.d/*
        host devbox
        """
        let hosts = SSHConfig.hosts(in: text) { pattern in
            pattern == "config.d/*" ? ["Host gpu \"quoted name\"\n  User me", "Host *"] : []
        }
        XCTAssertEqual(hosts, ["devbox", "prod-1", "staging", "gpu", "quoted name"])
    }

    func testIncludesStopAtTheDepthLimit() {
        let hosts = SSHConfig.hosts(in: "Include self\nHost a", include: { _ in ["Include self\nHost b"] }, depth: 2)
        XCTAssertEqual(hosts, ["b", "a"])
    }
}
