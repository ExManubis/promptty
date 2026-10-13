import AppKit
import Observation
import PaneActivity
import WorkspaceModel

/// Every pane's activity (what runs in it, what happened there unseen), for the tab rows and pane
/// headers, and the notices for what finished or needs the user while they looked elsewhere.
@MainActor
@Observable
final class ActivityTracker {
    /// What views read: republished only when what they show changes.
    private(set) var activities: [PaneID: PaneActivity] = [:]
    /// The full state, with the per-second bookkeeping views do not need.
    @ObservationIgnored private var states: [PaneID: PaneActivity] = [:]

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
    }

    /// The panes to watch right now; set by the coordinator.
    @ObservationIgnored var panes: () -> [Watched] = { [] }
    /// Whether the user sees one pane now; set by the coordinator.
    @ObservationIgnored var isSeen: (PaneID) -> Bool = { _ in false }
    /// A long command finished, a bell rang or a program asked for the user, unseen.
    @ObservationIgnored var onNotice: (PaneID, Notice) -> Void = { _, _ in }
    /// The user looked at a pane that had something unseen: its notification is out of date.
    @ObservationIgnored var onSeen: (PaneID) -> Void = { _ in }

    /// The first shell seen in a pane's foreground, for panes without PrompTTY's integration.
    @ObservationIgnored private var shellPIDs: [PaneID: Int] = [:]
    /// The last foreground pid read per pane, and what it was: the arguments are read once per pid.
    @ObservationIgnored private var identified: [PaneID: (pid: Int, foreground: PaneActivity.Foreground)] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var timerInterval: TimeInterval = 0.25
    /// When each pane's jobs last ran: the one timer ticks fast, panes the user cannot see run less.
    @ObservationIgnored private var cadence = PollCadence<Job>()
    private struct Job: Hashable {
        enum Kind: CaseIterable { case shell, foreground, screen }
        let pane: PaneID
        let kind: Kind
    }
    /// The last screen seen per agent pane, as a hash.
    @ObservationIgnored private var screens: [PaneID: Int] = [:]
    /// The folder each agent works in, read from its process.
    @ObservationIgnored private var agentDirectories: [PaneID: String] = [:]

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
    }

    func activity(for pane: PaneID) -> PaneActivity {
        activities[pane] ?? PaneActivity()
    }

    /// Polls the panes that are due: an idle shell's foreground every 0.25 s where the user looks
    /// (1 s elsewhere; a command's end in an unseen pane is thus noticed after about 2 s, as it
    /// takes two observations of the shell), the foreground process every 0.5 s (1 s), an agent's screen every 0.5 s (1.5 s).
    func tick() {
        let now = Date()
        var live = Set<PaneID>()
        let watchedPanes = panes()
        let wanted = watchedPanes.contains { $0.visible } ? 0.25 : 1
        if timer != nil, wanted != timerInterval { schedule(every: wanted) }
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
            if activity.program?.isAgent == true {
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
            if watched.seen, activity.hasUnseen {
                activity.seen()
                onSeen(watched.pane)
            }
            store(activity, for: watched.pane)
        }
        for gone in Set(states.keys).subtracting(live) {
            states[gone] = nil
            activities[gone] = nil
            shellPIDs[gone] = nil
            identified[gone] = nil
            screens[gone] = nil
            agentDirectories[gone] = nil
            for kind in Job.Kind.allCases { cadence.forget(Job(pane: gone, kind: kind)) }
        }
    }

    /// The shell reported how a command ended.
    func exitReported(_ pane: PaneID, code: Int) {
        var activity = states[pane] ?? PaneActivity()
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

    private func store(_ activity: PaneActivity, for pane: PaneID) {
        states[pane] = activity
        if activities[pane]?.visible != activity.visible { activities[pane] = activity }
    }

    private func foreground(of watched: Watched) -> PaneActivity.Foreground? {
        guard let pid = watched.foregroundPID(), pid > 0 else { return nil }
        if let shell = watched.shellPID() ?? shellPIDs[watched.pane], shell == pid {
            // Pids are reused: what ran before is forgotten once the shell is back.
            identified[watched.pane] = nil
            agentDirectories[watched.pane] = nil
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
        if case .program(let program) = foreground, program.isAgent {
            agentDirectories[watched.pane] = ProcessArguments.workingDirectory(pid: Int32(pid))
        } else {
            agentDirectories[watched.pane] = nil
        }
        return foreground
    }
}
