import AppKit
import Observation
import PaneActivity
import WorkspaceModel

/// Every pane's activity (what runs in it, what happened there unseen), for the tab rows and pane
/// headers, and the notices for what finished or needs the user while they looked elsewhere.
@MainActor
@Observable
final class ActivityTracker {
    private(set) var activities: [PaneID: PaneActivity] = [:]

    /// A pane to watch: its terminal, the shell's pid if known, and whether the user sees it.
    struct Watched {
        let pane: PaneID
        let foregroundPID: Int?
        let shellPID: Int?
        let seen: Bool
    }

    /// The panes to watch right now; set by the coordinator.
    @ObservationIgnored var panes: () -> [Watched] = { [] }
    /// A long command finished, a bell rang or a program asked for the user, unseen.
    @ObservationIgnored var onNotice: (PaneID, Notice) -> Void = { _, _ in }

    /// The first shell seen in a pane's foreground, for panes without PrompTTY's integration.
    @ObservationIgnored private var shellPIDs: [PaneID: Int] = [:]
    /// The last foreground pid read per pane, and what it was: the arguments are read once per pid.
    @ObservationIgnored private var identified: [PaneID: (pid: Int, foreground: PaneActivity.Foreground)] = [:]
    @ObservationIgnored private var timer: Timer?

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
            var activity = activities[watched.pane] ?? PaneActivity()
            if let foreground = foreground(of: watched) {
                if let notice = activity.observe(foreground, at: now, seen: watched.seen) {
                    onNotice(watched.pane, notice)
                }
            }
            if watched.seen { activity.seen() }
            if activities[watched.pane] != activity { activities[watched.pane] = activity }
        }
        for gone in Set(activities.keys).subtracting(live) {
            activities[gone] = nil
            shellPIDs[gone] = nil
            identified[gone] = nil
        }
    }

    /// The shell reported how a command ended.
    func exitReported(_ pane: PaneID, code: Int) {
        activities[pane, default: PaneActivity()].exitReported(code: code)
    }

    /// A bell or a program's notification. Returns false when the user sees the pane (nothing is
    /// marked).
    @discardableResult
    func attention(_ pane: PaneID, message: String?) -> Bool {
        let seen = panes().first { $0.pane == pane }?.seen ?? false
        guard !seen else { return false }
        var activity = activities[pane] ?? PaneActivity()
        if let notice = activity.attention(seen: false, message: message) { onNotice(pane, notice) }
        activities[pane] = activity
        return true
    }

    private func foreground(of watched: Watched) -> PaneActivity.Foreground? {
        guard let pid = watched.foregroundPID, pid > 0 else { return nil }
        if let shell = watched.shellPID ?? shellPIDs[watched.pane], shell == pid { return .shell }
        if let known = identified[watched.pane], known.pid == pid { return known.foreground }
        guard let process = ProcessArguments.read(pid: Int32(pid)) else { return nil }
        let program = ProgramCatalog.identify(executable: process.executable, arguments: process.arguments)
        // Before the integration reports the shell's pid (or without it): the first shell in front
        // is the pane's own.
        if program?.isShell == true, watched.shellPID == nil, shellPIDs[watched.pane] == nil {
            shellPIDs[watched.pane] = pid
            identified[watched.pane] = (pid, .shell)
            return .shell
        }
        // Until the pane's shell is known, its foreground is the shell starting (`login`).
        guard watched.shellPID != nil || shellPIDs[watched.pane] != nil else { return nil }
        let foreground: PaneActivity.Foreground = program.map { .program($0) } ?? .command
        identified[watched.pane] = (pid, foreground)
        return foreground
    }
}
