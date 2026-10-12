import Foundation

/// PrompTTY's zsh integration: the `.zshenv` that hides the prompt and reports each prompt to the
/// app, and the environment that makes zsh load it.
///
/// zsh reads `$ZDOTDIR/.zshenv` first. Ghostty's own integration also uses `ZDOTDIR`; it saves the
/// value it finds (ours), restores it, and sources `$ZDOTDIR/.zshenv`, so the chain is Ghostty →
/// PrompTTY → the user's files.
public enum ZshIntegration {
    /// The path prefix of the directory report the integration sends when zle starts reading a
    /// line: PrompTTY's "prompt ready" signal. No real directory lives there.
    public static let readyMarker = "/.promptty-ready"

    /// The directory inside a ready report, or nil when `path` is an ordinary directory report.
    public static func readyDirectory(fromReportedPath path: String) -> String? {
        guard path.hasPrefix(readyMarker + "/") || path == readyMarker else { return nil }
        let rest = String(path.dropFirst(readyMarker.count))
        return rest.isEmpty ? "/" : rest
    }

    public static func isZsh(shellPath: String) -> Bool {
        (shellPath as NSString).lastPathComponent == "zsh"
    }

    /// The variables a zsh pane starts with. `userZDOTDIR` is the app's own `ZDOTDIR`, if any,
    /// which the script restores before loading the user's files.
    public static func environment(integrationDirectory: URL, stateFile: URL, userZDOTDIR: String?) -> [String: String] {
        var env = ["ZDOTDIR": integrationDirectory.path, "PROMPTTY_STATE": stateFile.path]
        if let userZDOTDIR, !userZDOTDIR.isEmpty { env["PROMPTTY_ZDOTDIR"] = userZDOTDIR }
        return env
    }

    /// Writes `.zshenv` into `directory` (creating it) unless it already holds this exact script.
    @discardableResult
    public static func install(in directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(".zshenv")
        if (try? String(contentsOf: file, encoding: .utf8)) != zshenv {
            try zshenv.write(to: file, atomically: true, encoding: .utf8)
        }
        return directory
    }

    public static let zshenv = #"""
    # PrompTTY's zsh integration. PrompTTY writes this file at launch; edits are overwritten.
    #
    # From here on zsh behaves as if PrompTTY were not involved: the user's own files load from their
    # usual place. At the first prompt (after .zshrc) the input bar hooks are installed.

    if [[ -n "${PROMPTTY_ZDOTDIR+X}" ]]; then
        'builtin' 'export' ZDOTDIR="$PROMPTTY_ZDOTDIR"
        'builtin' 'unset' 'PROMPTTY_ZDOTDIR'
    else
        'builtin' 'unset' 'ZDOTDIR'
    fi
    'builtin' 'typeset' _promptty_file="${ZDOTDIR-$HOME}/.zshenv"
    [[ ! -r "$_promptty_file" ]] || 'builtin' 'source' '--' "$_promptty_file"
    'builtin' 'unset' '_promptty_file'

    if [[ -o 'interactive' ]]; then
        # Every prompt: hide zsh's own prompt (the input bar replaces it) and refresh what the bar
        # knows about the shell.
        _promptty_precmd() {
            'builtin' 'emulate' -L zsh -o no_aliases
            PROMPT='' RPROMPT=''
            _promptty_write_state
        }

        _promptty_preexec() {
            'builtin' 'print' -rn -- $'\e[?25h'
        }

        # zle is about to read a line: the prompt is ready. A theme that set its prompt after our
        # precmd is cleared here. Keys typed while a command ran (type-ahead) are dropped: they would
        # sit, invisible, in front of the next command from the bar. Then the cursor is hidden and
        # PrompTTY is told, with a directory report under a path only this integration uses,
        # followed by the real directory so the terminal's own record of it stays right.
        _promptty_line_init() {
            'builtin' 'emulate' -L zsh -o no_aliases
            if [[ -n "$PROMPT$RPROMPT" ]]; then
                PROMPT='' RPROMPT=''
                'builtin' 'zle' reset-prompt
            fi
            'builtin' 'local' _promptty_c
            while 'builtin' 'read' -t 0 -k 1 -s _promptty_c 2>/dev/null; do :; done
            'builtin' 'print' -rn -- $'\e[?25l\e]7;kitty-shell-cwd://'"${HOST}/.promptty-ready${PWD}"$'\a\e]7;kitty-shell-cwd://'"${HOST}${PWD}"$'\a'
        }

        # Lists what only the shell knows (history file, PATH, aliases, functions, builtins, reserved
        # words, exported names) for the bar's coloring and completion.
        _promptty_write_state() {
            'builtin' 'emulate' -L zsh -o no_aliases
            [[ -n "${PROMPTTY_STATE-}" ]] || return 0
            'builtin' 'zmodload' zsh/parameter 2>/dev/null
            {
                [[ -z "${HISTFILE-}" ]] || 'builtin' 'print' -r -- "histfile $HISTFILE"
                'builtin' 'print' -r -- "path $PATH"
                'builtin' 'print' -rl -- "${(@k)aliases/#/alias }" "${(@k)functions/#/function }" \
                    "${(@k)builtins/#/builtin }" "${(@)reswords/#/reserved }" \
                    "${(@k)parameters[(R)*export*]/#/export }"
            } >| "$PROMPTTY_STATE" 2>/dev/null
        }

        # Runs once, at the first prompt, so it comes after .zshrc. Ghostty's deferred init runs
        # after this and puts its own hook behind ours.
        _promptty_init() {
            precmd_functions=(${precmd_functions:#_promptty_*} _promptty_precmd)
            preexec_functions=(${preexec_functions:#_promptty_preexec} _promptty_preexec)
            # The bar cannot show a line zsh loads back for confirmation, so `!!` runs directly.
            'builtin' 'unsetopt' hist_verify
            'builtin' 'autoload' -Uz add-zle-hook-widget && add-zle-hook-widget line-init _promptty_line_init
            _promptty_precmd
        }

        'builtin' 'typeset' -ga precmd_functions preexec_functions
        precmd_functions+=(_promptty_init)
    fi
    """#
}

/// What the shell told PrompTTY about itself (see `_promptty_write_state`).
public struct ShellStateFile: Equatable, Sendable {
    public var historyFile: String?
    public var path: [String] = []
    public var aliases: Set<String> = []
    public var functions: Set<String> = []
    public var builtins: Set<String> = []
    public var reserved: Set<String> = []
    public var exports: Set<String> = []

    public init() {}

    /// Names that run without a `PATH` lookup.
    public var commandNames: Set<String> { aliases.union(functions).union(builtins).union(reserved) }

    public static func parse(_ text: String) -> ShellStateFile {
        var s = ShellStateFile()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let kind = line[..<space]
            let value = String(line[line.index(after: space)...])
            guard !value.isEmpty else { continue }
            switch kind {
            case "histfile": s.historyFile = value
            case "path": s.path = value.split(separator: ":").map(String.init)
            case "alias": s.aliases.insert(value)
            case "function": s.functions.insert(value)
            case "builtin": s.builtins.insert(value)
            case "reserved": s.reserved.insert(value)
            case "export": s.exports.insert(value)
            default: continue
            }
        }
        return s
    }
}
