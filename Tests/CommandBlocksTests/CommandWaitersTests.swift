import CommandBlocks
import Foundation
import Testing

private func running(_ command: String) -> (CommandLog, CommandRecord) {
    var log = CommandLog()
    let id = log.start(command).id
    return (log, log.record(id)!)
}

@Test func aWaiterIsAnsweredWhenItsCommandEnds() {
    var log = CommandLog()
    let id = log.start("make").id
    var waiters = CommandWaiters<String>()
    var got: [String] = []
    waiters.add(id, pane: "a") { outcome in
        if case .finished(let record) = outcome { got.append("\(record.id) \(record.exitCode ?? -1)") }
    }
    let ended = log.finish(code: 2)!
    for answer in waiters.finished(ended) { answer() }
    #expect(got == ["\(id) 2"])
    #expect(waiters.isEmpty)
}

@Test func closingAPaneAnswersEveryoneWaitingOnIt() {
    let (_, make) = running("make")
    let (_, other) = running("sleep 9")
    var waiters = CommandWaiters<String>()
    var closed = 0
    waiters.add(make.id, pane: "a") { if case .paneClosed = $0 { closed += 1 } }
    waiters.add(make.id, pane: "a") { if case .paneClosed = $0 { closed += 1 } }
    waiters.add(other.id, pane: "b") { _ in Issue.record("pane b is still open") }
    for answer in waiters.paneClosed("a") { answer() }
    #expect(closed == 2)
    #expect(waiters.count == 1)
    #expect(waiters.paneClosed("a").isEmpty)
}

@Test func aCancelledWaiterIsForgotten() {
    let (_, make) = running("make")
    var waiters = CommandWaiters<String>()
    let token = waiters.add(make.id, pane: "a") { _ in Issue.record("cancelled") }
    var answered = false
    waiters.add(make.id, pane: "a") { _ in answered = true }
    waiters.cancel(token)
    #expect(waiters.count == 1)
    for answer in waiters.finished(make) { answer() }
    #expect(answered)
    #expect(waiters.isEmpty)
}
