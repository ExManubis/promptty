import Foundation
import PaneActivity
import Preferences

/// The demo's Macs, tabs and screens, until the phone talks to a Mac (PTY-70, PTY-71).
@MainActor
enum DemoData {
    /// The demo's model; launched with `-open <tab title>` it opens that tab, and with
    /// `-activity YES` it shows the Activity (for screenshots and UI tests).
    static func model() -> PhoneModel {
        let model = PhoneModel(macs: macs, projects: projects, theme: ThemeCatalog.parse(flexokiDark)!)
        let defaults = UserDefaults.standard
        if let title = defaults.string(forKey: "open"), let tab = model.allTabs.first(where: { $0.title == title }) {
            model.select(tab.id)
        }
        model.showsActivity = defaults.bool(forKey: "activity")
        return model
    }

    static let macs = [
        PhoneMac(name: "Studio", host: "mikkels-studio", symbol: "macstudio", online: true, waiting: 1, status: "12 ms"),
        PhoneMac(name: "MacBook Pro", host: "mikkels-mbp", symbol: "laptopcomputer", online: true, status: "28 ms"),
        PhoneMac(name: "MacBook Air", host: "mikkels-air", symbol: "laptopcomputer", online: false, status: "asleep · 2h"),
    ]

    /// Ghostty's Flexoki Dark, the Mac's default dark theme. The Mac will send its own.
    static let flexokiDark = """
    palette = 0=#100f0f
    palette = 1=#d14d41
    palette = 2=#879a39
    palette = 3=#d0a215
    palette = 4=#4385be
    palette = 5=#ce5d97
    palette = 6=#3aa99f
    palette = 7=#878580
    palette = 8=#575653
    palette = 9=#af3029
    palette = 10=#66800b
    palette = 11=#ad8301
    palette = 12=#205ea6
    palette = 13=#a02f6f
    palette = 14=#24837b
    palette = 15=#cecdc3
    background = #100f0f
    foreground = #cecdc3
    """

    static func program(_ id: String) -> Program? { ProgramCatalog.all.first { $0.id == id } }

    static let repo = "~/Developer/promptty-2"

    static var projects: [PhoneProject] {
        [
            PhoneProject(name: "promptty-2", tabs: [remoteAPI, enginePatch, tests]),
            PhoneProject(name: "munin", tabs: [tracker, deploy]),
        ]
    }

    static var remoteAPI: PhoneTab {
        let claude = PhonePane(
            program: program("claude"), title: "Remote API", folder: repo, display: .permission, tool: "Bash",
            since: Date().addingTimeInterval(-40),
            screen: [
                TerminalLine("{3:*} Welcome to Claude Code"),
                TerminalLine(""),
                TerminalLine("> serve the control API over WebSocket"),
                TerminalLine(""),
                TerminalLine("● Read(Sources/RemoteControl/ControlSocket.swift)"),
                TerminalLine("{8:  ⎿  Read 214 lines}"),
                TerminalLine(""),
                TerminalLine("● The control socket already frames JSON lines, so the WebSocket server can reuse ControlWire as is."),
                TerminalLine(""),
                TerminalLine("● Update(Package.swift)"),
                TerminalLine("{8:  ⎿  Updated with 4 additions}"),
                TerminalLine("{2:     + .target(name: \"RemoteProtocol\"),}"),
                TerminalLine(""),
                TerminalLine("╭──────────────────────────────────────────╮"),
                TerminalLine("│ Bash command                             │"),
                TerminalLine("│   swift test --filter RemoteProtocol     │"),
                TerminalLine("│ Do you want to proceed?                  │"),
                TerminalLine("│ {4:❯ 1. Yes}                                 │"),
                TerminalLine("│   2. Yes, and don't ask again            │"),
                TerminalLine("│   3. No, and tell Claude what to do      │"),
                TerminalLine("╰──────────────────────────────────────────╯"),
            ],
            permission: PermissionRequest(agent: "Claude", tool: "Bash", command: "swift test --filter RemoteProtocol"))
        let shell = PhonePane(
            program: nil, title: "zsh", folder: repo,
            screen: [TerminalLine("{2:swift} build"), TerminalLine("{8:Build complete! (4.21s)}")],
            shell: ShellState(folder: repo, branch: "claude/pty-70-remote-api", dirty: true, lastExit: (0, 4.2)))
        return PhoneTab(title: "Remote API", panes: [claude, shell])
    }

    static var enginePatch: PhoneTab {
        PhoneTab(title: "Engine patch: pty tap", panes: [PhonePane(
            program: program("codex"), title: "Engine patch: pty tap", folder: repo, display: .working, tool: "Edit",
            since: Date().addingTimeInterval(-14 * 60),
            screen: [
                TerminalLine("> add ghostty_surface_set_output_tap (0005-pty-tap)"),
                TerminalLine(""),
                TerminalLine("• Edited Engine/patches/0005-pty-tap.patch {2:(+86 -0)}"),
                TerminalLine("• Running zig build test -Dtest-filter=tap"),
                TerminalLine("{8:  └ 3 of 4 tests passed}"),
                TerminalLine(""),
                TerminalLine("{3:◦ Working (14m · esc to interrupt)}"),
            ])])
    }

    static var tests: PhoneTab {
        PhoneTab(title: "zsh", panes: [PhonePane(
            program: nil, title: "zsh", folder: repo, display: .finished,
            screen: [
                TerminalLine("{2:git} log --oneline -4"),
                TerminalLine("{3:ed95774} Merge pull request #22 from claude/pty-80"),
                TerminalLine("{3:f91f422} build(packages): build for iOS too"),
                TerminalLine("{3:035aa74} chore(release): version 2.1"),
                TerminalLine("{3:155b721} feat(cli): new-window"),
                TerminalLine(""),
                TerminalLine("{2:./script/test}"),
                TerminalLine("{7:Executed 244 tests, with 0 failures}"),
                TerminalLine("** BUILD SUCCEEDED ** iOS Simulator"),
                TerminalLine("** BUILD SUCCEEDED ** PrompTTY.app"),
                TerminalLine("{2:OK}"),
            ],
            shell: ShellState(folder: repo, branch: "staging", dirty: true, lastExit: (0, 192)))], unseen: true)
    }

    static var tracker: PhoneTab {
        PhoneTab(title: "nvim", panes: [PhonePane(
            program: program("neovim"), title: "nvim", folder: "~/Developer/munin",
            screen: [
                TerminalLine("{8:  1} {5:from} fastapi {5:import} APIRouter"),
                TerminalLine("{8:  2}"),
                TerminalLine("{8:  3} router = APIRouter(prefix={2:\"/api\"})"),
                TerminalLine("{8:  4}"),
                TerminalLine("{8:  5} {4:@router.get}({2:\"/issues/:id\"})"),
                TerminalLine("{8:  6} {5:async def} {3:get_issue}(id: {6:str}):"),
                TerminalLine("{8:  7}     {5:return} {5:await} store.issue(id)"),
                TerminalLine(""),
                TerminalLine("{8:tracker/api.py                                 7,1   All}"),
            ])])
    }

    static var deploy: PhoneTab {
        let ssh = PhonePane(
            program: nil, title: "ssh", folder: "deploy@munin-01", display: .failed(1),
            screen: [
                TerminalLine("{2:journalctl} -u munin --since today {1:-p} err"),
                TerminalLine("{1:Oct 24 09:12:44 munin-01 munin[812]: database is locked}"),
                TerminalLine("{1:Oct 24 09:12:45 munin-01 munin[812]: retry 3/3 failed}"),
            ],
            shell: ShellState(folder: "deploy@munin-01:~", branch: nil, lastExit: (1, 0.3)))
        let docker = PhonePane(
            program: program("docker"), title: "docker", folder: "deploy@munin-01",
            screen: [TerminalLine("{2:docker} ps"), TerminalLine("munin-tracker   Up 3 days")])
        return PhoneTab(title: "ssh", panes: [ssh, docker])
    }
}
