// promptty: control PrompTTY from its own terminals (see `promptty help`). Every pane has it on
// its PATH, with `PROMPTTY_CONTROL` (the app's control socket) and `PROMPTTY_PANE_ID` (the pane).
import Darwin
import Foundation
import RemoteControl

signal(SIGPIPE, SIG_IGN)
let environment = ProcessInfo.processInfo.environment

func fail(_ message: String, _ status: ControlStatus) -> Never {
    FileHandle.standardError.write(Data(("promptty: " + message + "\n").utf8))
    exit(status.rawValue)
}

let parsed: ControlCommandLine.Parsed
do {
    parsed = try ControlCommandLine.parse(Array(CommandLine.arguments.dropFirst()), caller: environment[ControlEnvironment.paneVariable])
} catch {
    fail(error.message + "\n\n" + ControlCommandLine.help, .usage)
}

switch parsed {
case .help:
    print(ControlCommandLine.help)
    exit(0)
case .version:
    print("promptty 1")
    exit(0)
case .request(let request):
    guard let socket = environment[ControlEnvironment.socketVariable], !socket.isEmpty else {
        fail("not in a PrompTTY terminal (PROMPTTY_CONTROL is not set)", .unreachable)
    }
    guard let response = ControlClient.send(request, to: socket, timeout: ControlCommandLine.replyTimeout(for: request)) else {
        fail("PrompTTY is not reachable", .unreachable)
    }
    let out = request.wantsJSON ? (response.json ?? response.text) : response.text
    if response.status == 0 {
        if !out.isEmpty { print(out) }
    } else if !out.isEmpty {
        FileHandle.standardError.write(Data(("promptty: " + out + "\n").utf8))
    }
    exit(response.status)
}
