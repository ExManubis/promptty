import Foundation
import SessionDaemonCore
import SessionProtocol

// prompttyd: runs PrompTTY's panes' programs on ptys of its own, so they keep running when the
// app quits (PTY-77). The app starts it (`prompttyd --socket PATH`) in a session of its own and
// talks to it over that socket (SessionProtocol).

signal(SIGPIPE, SIG_IGN)
// Its own session: the app's going, or a terminal it was started from closing, doesn't end it.
signal(SIGHUP, SIG_IGN)

var arguments = CommandLine.arguments.dropFirst()
var socketPath: String?
while let argument = arguments.popFirst() {
    switch argument {
    case "--socket": socketPath = arguments.popFirst()
    case "--version":
        print("prompttyd \(SessionProtocol.version)")
        exit(0)
    default:
        FileHandle.standardError.write(Data("prompttyd: unknown option \(argument)\n".utf8))
        exit(2)
    }
}
guard let socketPath else {
    FileHandle.standardError.write(Data("usage: prompttyd --socket PATH\n".utf8))
    exit(2)
}

let daemon = Daemon(socketPath: socketPath)
do {
    try daemon.start()
} catch Daemon.Failure.running {
    // The app raced another launch: that one serves.
    exit(0)
} catch {
    FileHandle.standardError.write(Data("prompttyd: \(error)\n".utf8))
    exit(1)
}
dispatchMain()
