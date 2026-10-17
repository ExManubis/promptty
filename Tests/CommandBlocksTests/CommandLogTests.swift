import CommandBlocks
import Foundation
import Testing

@Test func aCommandGetsAnIdAndEndsWithItsExitCode() {
    var log = CommandLog()
    let id = log.start("make test").id
    #expect(id.hasPrefix("cmd:"))
    #expect(log.record(id)?.running == true)
    let finished = log.finish(code: 2)
    #expect(finished?.id == id)
    #expect(log.record(id)?.exitCode == 2)
    #expect(log.record(id)?.running == false)
}

@Test func anIdHandedOutBeforeTheCommandRanIsKept() {
    var log = CommandLog()
    let id = CommandLog.newID()
    #expect(log.start("npm run dev", id: id).id == id)
    #expect(log.record(id)?.command == "npm run dev")
}

@Test func aCommandThatNeverReportedItsEndIsOverWhenTheNextStarts() {
    var log = CommandLog()
    let first = log.start("ssh box").id
    let ended = log.start("ls").ended
    #expect(log.record(first)?.running == false)
    #expect(log.record(first)?.exitCode == nil)
    // Reported as ended, so whoever waits for it gets an answer.
    #expect(ended.map(\.id) == [first])
}

@Test func aCommandThatEndedIsNotEndedAgainByTheNext() {
    var log = CommandLog()
    log.start("ls")
    log.finish(code: 0)
    #expect(log.start("pwd").ended.isEmpty)
}

@Test func anUnknownExitCodeIsNil() {
    var log = CommandLog()
    let id = log.start("true").id
    log.finish(code: -1)
    #expect(log.record(id)?.exitCode == nil)
}

@Test func onlyTheNewestHundredAreKept() {
    var log = CommandLog()
    let first = log.start("echo 0").id
    for i in 1...CommandLog.limit { log.start("echo \(i)") }
    #expect(log.records.count == CommandLog.limit)
    #expect(log.record(first) == nil)
    #expect(log.count == CommandLog.limit + 1)
}

@Test func aRecordIsMatchedToItsBlockFromTheNewest() {
    var log = CommandLog()
    let a = log.start("ls").id
    log.finish(code: 0)
    let b = log.start("git status").id
    log.finish(code: 0)
    // Older blocks from before PrompTTY tracked the pane are in front.
    let commands: [String?] = ["old", "older", "ls", "git status"]
    #expect(log.blockIndex(of: log.record(a)!, commands: commands) == 2)
    #expect(log.blockIndex(of: log.record(b)!, commands: commands) == 3)
}

@Test func aBlockFromACommandNotRunFromTheBarShiftsTheMatch() {
    var log = CommandLog()
    let a = log.start("make").id
    log.finish(code: 0)
    log.start("ls")
    log.finish(code: 0)
    // A command typed into a program's own prompt made a block after `make`.
    let commands: [String?] = ["make", "python -c 1", "ls"]
    #expect(log.blockIndex(of: log.record(a)!, commands: commands) == 0)
}

@Test func aWrappedCommandStillMatches() {
    var log = CommandLog()
    let a = log.start("echo one   two").id
    #expect(log.blockIndex(of: log.record(a)!, commands: ["echo one\ntwo"]) == 0)
}

@Test func aBlockGoneFromTheScrollbackIsNotFound() {
    var log = CommandLog()
    let a = log.start("make").id
    for i in 0..<10 { log.start("echo \(i)") }
    #expect(log.blockIndex(of: log.record(a)!, commands: ["echo 8", "echo 9"]) == nil)
}
