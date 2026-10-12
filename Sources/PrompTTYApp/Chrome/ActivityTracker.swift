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
        let foregroundPID: Int?
        let shellPID: Int?
        let seen: Bool
        /// The pane's screen text, read only for agents (to tell working from waiting).
        let screen: () -> String?
        /// Screen changes before this are the terminal's doing (a resize, a key echoed).
        let quietUntil: Date?
    }

    /// The panes to watch right now; set by the coordinator.
    @ObservationIgnored var panes: () -> [Watched] = { [] }
    /// A long command finished, a bell rang or a program asked for the user, unseen.
    @ObservationIgnored var onNotice: (PaneID, Notice) -> Void = { _, _ in }
    /// The user looked at a pane that had something unseen: its notification is out of date.
    @ObservationIgnored var onSeen: (PaneID) -> Void = { _ in }

    /// The first shell seen in a pane's foreground, for panes without PrompTTY's integration.
    @ObservationIgnored private var shellPIDs: [PaneID: Int] = [:]
    /// The last foreground pid read per pane, and what it was: the arguments are read once per pid.
    @ObservationIgnored private var identified: [PaneID: (pid: Int, foreground: PaneActivity.Foreground)] = [:]
    @ObservationIgnored private var timer: Timer?
    /// The last screen seen per agent pane, as a hash.
    @ObservationIgnored private var screens: [PaneID: Int] = [:]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func activity(for pane: PaneID) -> PaneActivity {
        activities[pane] ?? PaneActivity()
    }

    /// Polls every pane: its foreground process, and whether the user sees it now.
    func tick() {
        let now = Date()
        var live = Set<PaneID>()
        for watched in panes() {
            live.insert(watched.pane)
            var activity = states[watched.pane] ?? PaneActivity()
            if let foreground = foreground(of: watched) {
                if let notice = activity.observe(foreground, at: now, seen: watched.seen) {
                    onNotice(watched.pane, notice)
                }
            }
            if activity.program?.isAgent == true, let text = watched.screen() {
                let hash = text.hashValue
                let redraw = watched.quietUntil.map { now < $0 } ?? false
                let changed = !redraw && (screens[watched.pane].map { $0 != hash } ?? false)
                screens[watched.pane] = hash
                if let notice = activity.agentScreen(changed: changed, at: now, seen: watched.seen) {
                    onNotice(watched.pane, notice)
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

    private func isSeen(_ pane: PaneID) -> Bool {
        panes().first { $0.pane == pane }?.seen ?? false
    }

    private func foreground(of watched: Watched) -> PaneActivity.Foreground? {
        guard let pid = watched.foregroundPID, pid > 0 else { return nil }
        if let shell = watched.shellPID ?? shellPIDs[watched.pane], shell == pid {
            // Pids are reused: what ran before is forgotten once the shell is back.
            identified[watched.pane] = nil
            return .shell
        }
        if let known = identified[watched.pane], known.pid == pid { return known.foreground }
        let process = ProcessArguments.read(pid: Int32(pid))
        // Without the integration: the first process in front that is not `login` starting the
        // shell is the pane's shell, whichever shell that is.
        if watched.shellPID == nil, shellPIDs[watched.pane] == nil {
            guard let process, (process.executable as NSString).lastPathComponent != "login" else { return nil }
            shellPIDs[watched.pane] = pid
            return .shell
        }
        // Unreadable (run as another user, as with sudo): something runs, unrecognised.
        let foreground: PaneActivity.Foreground = process
            .flatMap { ProgramCatalog.identify(executable: $0.executable, arguments: $0.arguments) }
            .map { .program($0) } ?? .command
        identified[watched.pane] = (pid, foreground)
        return foreground
    }
}
