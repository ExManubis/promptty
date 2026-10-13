// promptty-hook: run by an agent's hooks inside a PrompTTY pane, tells the app what the agent does.
//
//     promptty-hook <Event>           Claude Code: the hook's JSON on standard input
//     promptty-hook [codex-notify] <json>   Codex `notify`: the JSON as the last argument
//
// It adds the pane (`PROMPTTY_PANE_ID`) and sends one line to the app's socket (`PROMPTTY_SOCKET`).
// It never holds up or fails the agent: it prints nothing, always exits 0, and is gone within
// 200 ms whatever happens. Outside PrompTTY (no variables) it does nothing.
import AgentHooks
import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)
let watchdog = DispatchSource.makeTimerSource(queue: .global())
watchdog.schedule(deadline: .now() + .milliseconds(200))
// Not isolated to the main actor as top-level code is: it runs on a global queue.
watchdog.setEventHandler { @Sendable in _exit(0) }
watchdog.resume()

let environment = ProcessInfo.processInfo.environment
guard let pane = environment[HookEnvironment.paneVariable].flatMap(UUID.init(uuidString:)),
      let socketPath = environment[HookEnvironment.socketVariable], !socketPath.isEmpty else { exit(0) }

let arguments = Array(CommandLine.arguments.dropFirst())
// Codex passes the event as JSON in the last argument.
let inline = arguments.last { $0.hasPrefix("{") }
let event = arguments.first { !$0.hasPrefix("{") } ?? (inline != nil ? HookEvent.codexNotify.rawValue : "")

/// Standard input up to its end (Claude Code closes it after the JSON), at most 16 MB; nothing when
/// it is a terminal (run by hand).
func readInput() -> Data {
    guard isatty(STDIN_FILENO) == 0 else { return Data() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while data.count < 16 << 20 {
        let n = read(STDIN_FILENO, &buffer, buffer.count)
        if n > 0 { data.append(buffer, count: n) } else if n < 0, errno == EINTR { continue } else { break }
    }
    return data
}

let input = inline.map { Data($0.utf8) } ?? readInput()
guard let line = HookMessage.line(pane: pane, event: event, input: input) else { exit(0) }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var on: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
// Non-blocking: an app that is not listening, or not reading, is not waited for.
_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    raw.copyBytes(from: pathBytes)
    raw[pathBytes.count] = 0
}
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
if connected == 0 {
    line.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { break }
        }
    }
}
close(fd)
exit(0)
