import AgentHooks
import AppKit
import GhosttyBridge
import Observation
import PaneActivity
import WorkspaceModel

/// What one pane's rows and header show of it, observed on its own: a change in one pane redraws
/// only the views of that pane. More of what a pane shows (its progress, an agent's own report of
/// its state) belongs here, beside its activity.
@MainActor
@Observable
final class PaneStatus {
    /// The pane's activity as views show it; set only when that changes.
    fileprivate(set) var activity = PaneActivity().visible {
        didSet { if display != activity.display { display = activity.display } }
    }
    /// What the activity shows alone (working, waiting, finished…), for the tab rows' marks: an
    /// agent moving from one tool to the next does not reach them.
    private(set) var display = PaneActivity().visible.display
    /// The link under the pointer, shown at the pane's corner; nil when there is none.
    private(set) var hoveredLink: String?

    /// Secure keyboard input is on for the pane (it asked for it, or the user forced it).
    private(set) var secure = false

    /// A program waits to read or write the clipboard until the user answers, in the pane's banner.
    private(set) var clipboardRequest: ClipboardTicket?

    func setClipboardRequest(_ ticket: ClipboardTicket?) {
        if clipboardRequest != ticket { clipboardRequest = ticket }
    }

    /// What a program reports of its progress (OSC 9;4); nil when it reports none.
    private(set) var progress: PaneProgress?

    func setProgress(_ progress: PaneProgress?) {
        if self.progress != progress { self.progress = progress }
    }

    /// Where an `ssh` in front of the pane is connected (`user@host`); nil when none runs.
    private(set) var remoteHost: String?

    func setRemoteHost(_ host: String?) {
        if remoteHost != host { remoteHost = host }
    }

    /// The pane printed new lines while the user was not looking (not an agent's: those say more).
    private(set) var unseenOutput = false

    func setUnseenOutput(_ on: Bool) {
        if unseenOutput != on { unseenOutput = on }
    }

    /// The TCP ports the pane's programs listen on (a dev server's), lowest first.
    private(set) var ports: [Int] = []

    func setPorts(_ ports: [Int]) {
        if self.ports != ports { self.ports = ports }
    }

    /// The pane's find bar; nil while it is closed.
    private(set) var find: PaneFind?

    func setFind(_ find: PaneFind?) {
        if self.find != find { self.find = find }
    }

    /// Changes the open find bar; nothing while it is closed.
    func updateFind(_ change: (inout PaneFind) -> Void) {
        guard var find else { return }
        change(&find)
        setFind(find)
    }

    func setSecure(_ on: Bool) {
        if secure != on { secure = on }
    }

    /// Moves arrive with every mouse move over text; an unchanged link changes nothing.
    func hover(over link: String?) {
        if hoveredLink != link { hoveredLink = link }
    }
}

/// A pane's find bar: what it looks for and what the terminal found.
struct PaneFind: Equatable {
    var needle = ""
    /// Matches in the scrollback; nil while the terminal counts, or before anything is looked for.
    var total: Int?
    /// The current match, 0-based.
    var selected: Int?
    /// Bumped to put the keyboard in the field again (⌘F with the bar open).
    var focusRequest = 0
}

/// Every pane's activity (what runs in it, what happened there unseen), for the tab rows and pane
/// headers, and the notices for what finished or needs the user while they looked elsewhere.
@MainActor
final class ActivityTracker {
    /// What views read, a box per pane: a view observes the boxes it reads.
    private var statuses: [PaneID: PaneStatus] = [:]
    /// The full state, with the per-second bookkeeping views do not need.
    private var states: [PaneID: PaneActivity] = [:]

    /// A pane to watch: its terminal, the shell's pid if known, and whether the user sees it.
    struct Watched {
        let pane: PaneID
        let foregroundPID: () -> Int?
        let shellPID: () -> Int?
        /// The user is (or could be) looking: a selected tab of an on-screen window. Polled quickly.
        let visible: Bool
        /// Visible, and the app in front with the window main: notices are for what happens elsewhere.
        let seen: Bool
        /// Lets an idle shell notice a program that took the terminal without the bar (`fg`, a hook).
        let checkShell: () -> Void
        /// The pane's screen text, read only for agents (to tell working from waiting).
        let screen: () -> String?
        /// Screen changes before this are the terminal's doing (a resize, a key echoed).
        let quietUntil: Date?
        /// The user's last key in the pane that answers a prompt (Return, Esc, y, n, a digit): it
        /// ends an agent's permission prompt.
        let lastAnswerKey: Date?
    }

    /// The panes to watch right now; set by the coordinator.
    var panes: () -> [Watched] = { [] }
    /// Every pane in the workspace, with a terminal or not; set by the coordinator.
    var allPanes: () -> Set<PaneID> = { [] }
    /// Whether the user sees one pane now; set by the coordinator.
    var isSeen: (PaneID) -> Bool = { _ in false }
    /// A long command finished, a bell rang or a program asked for the user, unseen.
    var onNotice: (PaneID, Notice) -> Void = { _, _ in }
    /// The user looked at a pane that had something unseen: its notification is out of date.
    var onSeen: (PaneID) -> Void = { _ in }
    /// After every tick (at most 4 times a second) while a window is on screen, for work that goes
    /// with the polling.
    var afterTick: () -> Void = {}

    /// The first shell seen in a pane's foreground, for panes without PrompTTY's integration.
    private var shellPIDs: [PaneID: Int] = [:]
    /// The last foreground pid read per pane, and what it was: the arguments are read once per pid.
    private var identified: [PaneID: (pid: Int, foreground: PaneActivity.Foreground)] = [:]
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0.25
    /// When each pane's jobs last ran: the one timer ticks fast, panes the user cannot see run less.
    private var cadence = PollCadence<Job>()
    private struct Job: Hashable {
        enum Kind: CaseIterable { case shell, foreground, screen, ports }
        let pane: PaneID
        let kind: Kind
    }
    /// The last screen seen per agent pane, as a hash.
    private var screens: [PaneID: Int] = [:]
    /// Where each pane's `ssh` (or `mosh`) is connected, read from its arguments.
    private var remoteHosts: [PaneID: String] = [:]
    /// The folder each agent works in, read from its process.
    private var agentDirectories: [PaneID: String] = [:]
    /// Each pane's scrollback length as last reported, to tell new lines from redraws.
    private var rowTotals: [PaneID: UInt64] = [:]
    /// The panes the user saw at the last tick: cheap to ask on every scroll report.
    private var seenAtTick: Set<PaneID> = []
    /// Whether panes mark output printed while unseen; set by the coordinator from Settings.
    var marksUnseenOutput = true
    /// Panes whose listening ports are being looked up, off the main thread.
    private var portLookups: Set<PaneID> = []
    /// The panes showing a progress report, for dropping the ones not renewed in time at a tick.
    private var progressing: Set<PaneID> = []
    /// What each pane's agent reported through its hooks (Claude Code's), while they are in charge
    /// of its state: then its screen is not watched.
    private var hooks: [PaneID: AgentHookState] = [:]
    /// The agent each pane's hooks came from: another agent in front later is not theirs.
    private var hookPrograms: [PaneID: String] = [:]
    /// While hooks say an agent works: its screen as a hash, and when that last changed. An
    /// interrupted turn runs no hook; a screen gone still says it.
    private var hookScreens: [PaneID: (hash: Int, changed: Date)] = [:]
    /// What programs report of themselves (OSC 7501), per pane: while there are records they set
    /// the pane's state (an agent's hooks still come first), and its screen is not watched.
    private var programStatuses: [PaneID: ProgramStatusRecords] = [:]
    /// The foreground process when each pane's records last changed: another in front means the
    /// program that reported quit, and its work with it.
    private var statusPIDs: [PaneID: Int] = [:]
    /// The panes whose progress ring a status report set.
    private var statusProgress: Set<PaneID> = []

    /// The folder an agent's process works in (it may differ from the shell's: `cd x && claude`).
    func agentDirectory(for pane: PaneID) -> String? { agentDirectories[pane] }

    func start() {
        schedule(every: 0.25)
        // A window coming back on screen is noticed at once, not at the slow timer's next tick.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// One timer for every pane: 0.25 s is what a program started by `fg` may wait to be noticed
    /// in a pane the user sees; the rest of the panes' jobs run on their own cadence. With no
    /// window on screen the timer itself slows to 1 s.
    private func schedule(every interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.4
        self.timer = timer
        timerInterval = interval
        cadence.slack = interval * 0.45
    }

    /// A pane's box, made on first use: a view reading it before the pane is watched sees the
    /// pane's activity once it is.
    func status(for pane: PaneID) -> PaneStatus {
        if let status = statuses[pane] { return status }
        let status = PaneStatus()
        statuses[pane] = status
        return status
    }

    /// What views show of a pane's activity (observes that pane alone).
    func activity(for pane: PaneID) -> PaneActivity.Visible { status(for: pane).activity }

    /// A pane's full state, unobserved, for actions (whether a command runs).
    func state(for pane: PaneID) -> PaneActivity { states[pane] ?? PaneActivity() }

    /// Polls the panes that are due: an idle shell's foreground every 0.25 s where the user looks
    /// (1 s elsewhere; a command's end in an unseen pane is thus noticed after about 2 s, as it
    /// takes two observations of the shell), the foreground process every 0.5 s (1 s), an agent's screen every 0.5 s (1.5 s).
    func tick() {
        let now = Date()
        var live = Set<PaneID>()
        let watchedPanes = panes()
        seenAtTick = Set(watchedPanes.lazy.filter(\.seen).map(\.pane))
        let onScreen = watchedPanes.contains { $0.visible }
        let wanted = onScreen ? 0.25 : 1
        if timer != nil, wanted != timerInterval { schedule(every: wanted) }
        var portRoots: [(pane: PaneID, root: Int32)] = []
        for watched in watchedPanes {
            live.insert(watched.pane)
            if cadence.isDue(Job(pane: watched.pane, kind: .shell), every: watched.visible ? 0.25 : 1, at: now) {
                watched.checkShell()
            }
            var activity = states[watched.pane] ?? PaneActivity()
            if cadence.isDue(Job(pane: watched.pane, kind: .foreground), every: watched.visible ? 0.5 : 1, at: now),
               let foreground = foreground(of: watched) {
                if let notice = activity.observe(foreground, at: now, seen: watched.seen) {
                    onNotice(watched.pane, notice)
                }
            }
            let agentInFront = activity.program?.isAgent == true
            if hooks[watched.pane] != nil { checkHooks(watched, activity: activity, at: now) }
            if programStatuses[watched.pane] != nil { checkProgramStatus(watched.pane, into: &activity, at: now) }
            if hooks[watched.pane] != nil {
                screens[watched.pane] = nil
                watchStillness(watched, at: now)
                reportHooks(watched.pane, into: &activity, at: now, seen: watched.seen)
            } else if programStatuses[watched.pane] != nil {
                screens[watched.pane] = nil
                reportProgramStatus(watched.pane, into: &activity, at: now, seen: watched.seen)
                if watched.seen { programStatusSeen(watched.pane, into: &activity) }
            } else if agentInFront {
                if cadence.isDue(Job(pane: watched.pane, kind: .screen), every: watched.visible ? 0.5 : 1.5, at: now),
                   let text = watched.screen() {
                    let hash = text.hashValue
                    let redraw = watched.quietUntil.map { now < $0 } ?? false
                    let changed = !redraw && (screens[watched.pane].map { $0 != hash } ?? false)
                    screens[watched.pane] = hash
                    if let notice = activity.agentScreen(changed: changed, at: now, seen: watched.seen) {
                        onNotice(watched.pane, notice)
                    }
                }
            } else {
                screens[watched.pane] = nil
            }
            if onScreen, let root = portLookupRoot(watched, at: now) { portRoots.append((watched.pane, root)) }
            status(for: watched.pane).setRemoteHost(remoteHosts[watched.pane])
            if watched.seen { statuses[watched.pane]?.setUnseenOutput(false) }
            if watched.seen, activity.hasUnseen {
                activity.seen()
                onSeen(watched.pane)
            }
            store(activity, for: watched.pane)
        }
        if !progressing.isEmpty {
            for pane in progressing where statuses[pane]?.progress?.isStale(at: now) != false { clearProgress(pane) }
        }
        for gone in Set(states.keys).subtracting(live) {
            states[gone] = nil
            clearProgress(gone)
            statuses[gone]?.hover(over: nil)
            statuses[gone]?.setPorts([])
            statuses[gone]?.setUnseenOutput(false)
            rowTotals[gone] = nil
            if let status = statuses[gone], status.activity != PaneActivity().visible { status.activity = PaneActivity().visible }
            shellPIDs[gone] = nil
            identified[gone] = nil
            screens[gone] = nil
            agentDirectories[gone] = nil
            remoteHosts[gone] = nil
            statuses[gone]?.setRemoteHost(nil)
            hooks[gone] = nil
            hookPrograms[gone] = nil
            hookScreens[gone] = nil
            programStatuses[gone] = nil
            statusPIDs[gone] = nil
            statusProgress.remove(gone)
            for kind in Job.Kind.allCases { cadence.forget(Job(pane: gone, kind: kind)) }
        }
        // A box is kept while its pane exists (a view may hold it before the pane has a
        // terminal), dropped once the pane is closed.
        if statuses.count > live.count {
            let existing = allPanes()
            for gone in statuses.keys where !live.contains(gone) && !existing.contains(gone) { statuses[gone] = nil }
        }
        lookUpPorts(portRoots)
        if onScreen { afterTick() }
    }

    /// A program reports progress (`kind` nil: it removes it). The report stands until the next one,
    /// the command's end, or 15 s without any.
    func reportProgress(_ pane: PaneID, kind: PaneProgress.Kind?, percent: Int?) {
        let progress = PaneProgress(kind: kind, percent: percent, at: Date())
        status(for: pane).setProgress(progress)
        if progress != nil { progressing.insert(pane) } else { progressing.remove(pane) }
    }

    func clearProgress(_ pane: PaneID) { reportProgress(pane, kind: nil, percent: nil) }

    /// The pane's scrollback (with its screen) is `total` rows now; reported with every scroll, so
    /// thousands of times a second while a program streams. More rows than before, in a pane the
    /// user does not see, is new output. A full-screen program redraws without adding rows.
    func rowsReported(_ pane: PaneID, total: UInt64) {
        let before = rowTotals[pane]
        rowTotals[pane] = total
        guard marksUnseenOutput, let before, total > before else { return }
        let status = status(for: pane)
        guard !status.unseenOutput, !seenAtTick.contains(pane), status.activity.program?.isAgent != true else { return }
        status.setUnseenOutput(true)
    }

    /// The shell reported how a command ended.
    func exitReported(_ pane: PaneID, code: Int) {
        var activity = states[pane] ?? PaneActivity()
        // Back at the prompt: what a program reported underway is over.
        if programStatuses[pane] != nil { updateProgramStatus(pane, into: &activity, at: Date()) { $0.endWork() } }
        if let notice = activity.exitReported(code: code, at: Date(), seen: isSeen(pane)) { onNotice(pane, notice) }
        store(activity, for: pane)
    }

    /// A bell or a program's notification. Returns false when the user sees the pane (nothing is
    /// marked).
    @discardableResult
    func attention(_ pane: PaneID, message: String?) -> Bool {
        guard !isSeen(pane) else { return false }
        var activity = states[pane] ?? PaneActivity()
        if let notice = activity.attention(seen: false, message: message) { onNotice(pane, notice) }
        store(activity, for: pane)
        return true
    }

    // MARK: Program status

    /// A program in the pane reported its status (OSC 7501).
    func programStatus(_ pane: PaneID, _ report: ProgramStatusReport) {
        // Only panes with a terminal, as for hooks.
        guard var activity = states[pane] else { return }
        updateProgramStatus(pane, into: &activity, at: Date()) { $0.apply(report, at: Date()) }
        store(activity, for: pane)
    }

    /// For the debug driver: a pane's program status records.
    func programStatusRecords(for pane: PaneID) -> ProgramStatusRecords? { programStatuses[pane] }

    private func updateProgramStatus(_ pane: PaneID, into activity: inout PaneActivity, at now: Date,
                                     _ change: (inout ProgramStatusRecords) -> Void) {
        var records = programStatuses[pane] ?? ProgramStatusRecords()
        change(&records)
        programStatuses[pane] = records.isEmpty ? nil : records
        statusPIDs[pane] = records.isEmpty ? nil : identified[pane]?.pid
        reportProgramStatus(pane, into: &activity, at: now, seen: isSeen(pane))
    }

    /// At a tick: another process in front than when the records last changed means the program
    /// that reported quit (or handed over), so its work is over.
    private func checkProgramStatus(_ pane: PaneID, into activity: inout PaneActivity, at now: Date) {
        guard let pid = identified[pane]?.pid, let reported = statusPIDs[pane], pid != reported else { return }
        updateProgramStatus(pane, into: &activity, at: now) { $0.endWork() }
    }

    /// The user saw the pane: finished work reported there has been looked at.
    private func programStatusSeen(_ pane: PaneID, into activity: inout PaneActivity) {
        guard var records = programStatuses[pane] else { return }
        records.seen()
        programStatuses[pane] = records.isEmpty ? nil : records
        if records.isEmpty { reportProgramStatus(pane, into: &activity, at: Date(), seen: true) }
    }

    /// Hands the pane's most urgent record to its activity and its progress ring (again at every
    /// tick, as for hooks); with none left, the pane's state is read as before. Hooks come first.
    private func reportProgramStatus(_ pane: PaneID, into activity: inout PaneActivity, at now: Date, seen: Bool) {
        guard hooks[pane] == nil else { return }
        guard let record = programStatuses[pane]?.current, let report = record.report.agentReport else {
            activity.programStatusEnded()
            showStatusProgress(pane, nil)
            return
        }
        if let notice = activity.programReported(report, since: record.since, at: now, seen: seen) { onNotice(pane, notice) }
        showStatusProgress(pane, record.report)
    }

    /// A working or blocked record's percentage shows in the pane's progress ring (a blocked one
    /// paused); one without leaves the ring to OSC 9;4.
    private func showStatusProgress(_ pane: PaneID, _ report: ProgramStatusReport?) {
        guard let report, let percent = report.progress else {
            if statusProgress.remove(pane) != nil { status(for: pane).setProgress(nil) }
            return
        }
        let kind: PaneProgress.Kind = report.state == .blocked ? .pause : .set
        let fraction = Double(min(max(percent, 0), 100)) / 100
        let current = status(for: pane).progress
        guard current?.kind != kind || current?.fraction != fraction else { return }
        status(for: pane).setProgress(PaneProgress(kind: kind, percent: percent, at: Date()))
        statusProgress.insert(pane)
        progressing.remove(pane)
    }

    // MARK: Hooks

    /// A message from an agent's hook in a pane (see `HookListener`).
    func hookMessage(_ message: HookMessage) {
        let pane = PaneID(rawValue: message.pane)
        // Only panes with a terminal: a message naming another is stale or made up.
        guard var activity = states[pane] else { return }
        let now = Date()
        let seen = isSeen(pane)
        if message.event == .codexNotify {
            // Codex says only that a turn ended; its work is still read off the screen.
            if message.payload.type == "agent-turn-complete", let notice = activity.agentTurnEnded(at: now, seen: seen) {
                onNotice(pane, notice)
            }
        } else {
            var hook = hooks[pane] ?? AgentHookState()
            hook.apply(message.event, message.payload, at: now)
            if hook.reportsEveryChange {
                hooks[pane] = hook
                if let program = activity.program, program.isAgent { hookPrograms[pane] = program.id }
            } else {
                // The session ended: the screen tells again.
                hooks[pane] = nil
                hookScreens[pane] = nil
                hookPrograms[pane] = nil
            }
            reportHooks(pane, into: &activity, at: now, seen: seen)
        }
        store(activity, for: pane)
    }

    /// What a pane's agent reported through its hooks, unobserved (for the debug driver).
    func hookState(for pane: PaneID) -> AgentHookState? { hooks[pane] }

    /// At a tick: hooks fall silent (ten minutes without a word and no agent in front) or belong to
    /// an agent no longer in front, and a key pressed at a permission prompt answers it.
    private func checkHooks(_ watched: Watched, activity: PaneActivity, at now: Date) {
        guard var hook = hooks[watched.pane] else { return }
        let agent = activity.program.flatMap { $0.isAgent ? $0.id : nil }
        let otherAgent = agent != nil && hookPrograms[watched.pane].map { $0 != agent } == true
        guard !otherAgent, hook.isActive(at: now, agentInFront: agent != nil) else {
            hooks[watched.pane] = nil
            hookScreens[watched.pane] = nil
            hookPrograms[watched.pane] = nil
            return
        }
        if let agent, hookPrograms[watched.pane] == nil { hookPrograms[watched.pane] = agent }
        if let key = watched.lastAnswerKey, let since = hook.since, key > since {
            hook.userResponded(at: key)
            hooks[watched.pane] = hook
        }
    }

    /// While the hooks say the agent works, its screen is still checked (on the screen job's
    /// cadence): still for a while, with no hook since, the turn was interrupted (Esc, ⌃C, a
    /// permission prompt answered "no"), and the agent waits for a prompt.
    private func watchStillness(_ watched: Watched, at now: Date) {
        guard var hook = hooks[watched.pane], hook.phase == .working else {
            hookScreens[watched.pane] = nil
            return
        }
        guard cadence.isDue(Job(pane: watched.pane, kind: .screen), every: watched.visible ? 0.5 : 1.5, at: now),
              let text = watched.screen() else { return }
        let hash = text.hashValue
        // The first look is a change: nothing is known of before.
        let changed = hookScreens[watched.pane].flatMap { $0.hash == hash ? $0.changed : nil } ?? now
        hookScreens[watched.pane] = (hash, changed)
        if hook.screenStill(since: changed, at: now) {
            hooks[watched.pane] = hook
            hookScreens[watched.pane] = nil
        }
    }

    /// Hands the hooks' state to the pane's activity (again at every tick: the agent may be
    /// recognised in front only after its first hooks ran).
    private func reportHooks(_ pane: PaneID, into activity: inout PaneActivity, at now: Date, seen: Bool) {
        guard let hook = hooks[pane], let phase = hook.phase else { return }
        let report: PaneActivity.AgentReport = switch phase {
        case .ready: .ready
        case .working: .working(tool: hook.tool)
        case .permission: .permission(hook.message)
        case .waitingForInput: .waitingForInput(hook.message)
        case .turnEnded: .turnEnded
        }
        if let notice = activity.agentReported(report, since: hook.since ?? now, at: now, seen: seen) { onNotice(pane, notice) }
    }

    /// Every 3 s where the user looks (5 s elsewhere): the ports the pane's shell and everything
    /// under it listen on, so a server started in the background counts too. The pane's root
    /// process when its look is due. Nothing is looked up while no window is on screen; one coming
    /// back is looked at once (its tick is due by then).
    private func portLookupRoot(_ watched: Watched, at now: Date) -> Int32? {
        let pane = watched.pane
        guard !portLookups.contains(pane),
              cadence.isDue(Job(pane: pane, kind: .ports), every: watched.visible ? 3 : 5, at: now),
              let root = watched.shellPID() ?? shellPIDs[pane] ?? watched.foregroundPID() else { return nil }
        return Int32(root)
    }

    /// Looks up the due panes' ports off the main thread, from one read of the process table for
    /// all of them. A shell with no children is skipped without a look at its sockets.
    private func lookUpPorts(_ roots: [(pane: PaneID, root: Int32)]) {
        guard !roots.isEmpty else { return }
        let panes = roots.map(\.pane)
        portLookups.formUnion(panes)
        Task.detached(priority: .utility) { [weak self] in
            var found: [PaneID: [Int]] = [:]
            if let processes = ProcessTree.snapshot() {
                for (pane, root) in roots {
                    found[pane] = processes.hasChildren(root) ? ListeningPorts.find(root: root, in: processes) : []
                }
            }
            await self?.portsFound(found, lookedUp: panes)
        }
    }

    /// `found` is empty when the process table could not be read: the panes keep what they show.
    private func portsFound(_ found: [PaneID: [Int]], lookedUp panes: [PaneID]) {
        portLookups.subtract(panes)
        for (pane, ports) in found {
            // Gone while looking: its box is dropped, or about to be.
            guard states[pane] != nil else { continue }
            status(for: pane).setPorts(ports)
        }
    }

    private func store(_ activity: PaneActivity, for pane: PaneID) {
        states[pane] = activity
        let status = status(for: pane)
        if status.activity != activity.visible { status.activity = activity.visible }
    }

    private func foreground(of watched: Watched) -> PaneActivity.Foreground? {
        guard let pid = watched.foregroundPID(), pid > 0 else { return nil }
        if let shell = watched.shellPID() ?? shellPIDs[watched.pane], shell == pid {
            // Pids are reused: what ran before is forgotten once the shell is back.
            identified[watched.pane] = nil
            agentDirectories[watched.pane] = nil
            remoteHosts[watched.pane] = nil
            return .shell
        }
        if let known = identified[watched.pane], known.pid == pid { return known.foreground }
        let process = ProcessArguments.read(pid: Int32(pid))
        // Without the integration: the first process in front that is not `login` starting the
        // shell is the pane's shell, whichever shell that is.
        if watched.shellPID() == nil, shellPIDs[watched.pane] == nil {
            guard let process, (process.executable as NSString).lastPathComponent != "login" else { return nil }
            shellPIDs[watched.pane] = pid
            return .shell
        }
        // Unreadable (run as another user, as with sudo): something runs, unrecognised.
        let foreground: PaneActivity.Foreground = process
            .flatMap { ProgramCatalog.identify(executable: $0.executable, arguments: $0.arguments) }
            .map { .program($0) } ?? .command
        identified[watched.pane] = (pid, foreground)
        if case .program(let program) = foreground, program.id == "ssh", let process {
            remoteHosts[watched.pane] = SSHCommand.destination(arguments: process.arguments)
        } else {
            remoteHosts[watched.pane] = nil
        }
        if case .program(let program) = foreground, program.isAgent {
            agentDirectories[watched.pane] = ProcessArguments.workingDirectory(pid: Int32(pid))
        } else {
            agentDirectories[watched.pane] = nil
        }
        return foreground
    }
}
