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
    /// which the script restores before loading the user's files. `historyFile` replaces the
    /// user's history file from the first prompt on (a driven debug run's own, so its commands
    /// never reach the user's real history).
    public static func environment(integrationDirectory: URL, stateFile: URL, userZDOTDIR: String?, historyFile: URL? = nil) -> [String: String] {
        var env = ["ZDOTDIR": integrationDirectory.path, "PROMPTTY_STATE": stateFile.path]
        if let userZDOTDIR, !userZDOTDIR.isEmpty { env["PROMPTTY_ZDOTDIR"] = userZDOTDIR }
        if let historyFile { env["PROMPTTY_HISTFILE"] = historyFile.path }
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
        # A tab reopened at launch: what it showed before the app quit, printed once above the
        # first prompt (before the user's files print anything of their own).
        if [[ -n "${PROMPTTY_RESTORE-}" ]]; then
            if [[ -r "$PROMPTTY_RESTORE" ]]; then
                'builtin' 'print' -rn -- "$(<"$PROMPTTY_RESTORE")"$'\r\n'
                'command' 'rm' -f -- "$PROMPTTY_RESTORE" 2>/dev/null
            fi
            'builtin' 'unset' 'PROMPTTY_RESTORE'
        fi

        # The prompt PrompTTY shows instead of zsh's: nothing, but the marks (OSC 133) that tell
        # the terminal a prompt waiting for input starts here, which is how it finds where each
        # command starts. In the prompt, zero-width, they are printed again whenever zsh redraws
        # the line (clearing the screen, resizing). Without prompt escapes they would show. In
        # REPLY; called before `emulate`, which would hide the user's own prompt_percent.
        _promptty_prompt() {
            REPLY=''
            [[ ! -o prompt_percent ]] || REPLY=$'%{\e]133;P;k=i\a\e]133;B\a%}'
        }

        # Every prompt: hide zsh's own prompt (the input bar replaces it) and refresh what the bar
        # knows about the shell. After a command, the terminal is asked to leave a blank row before
        # the prompt (PrompTTY's OSC 133;L;gap=1): only it knows whether the row above is blank
        # already, as when the command printed nothing.
        _promptty_precmd() {
            'builtin' 'local' REPLY
            _promptty_prompt
            'builtin' 'emulate' -L zsh -o no_aliases
            PROMPT="$REPLY" RPROMPT=''
            if (( ${_promptty_gap:-0} )); then
                _promptty_gap=0
                'builtin' 'print' -rn -- $'\e]133;L;gap=1\a'
            fi
            _promptty_write_state
        }

        # A command runs: its output starts after a blank row, and a blank row will follow it,
        # unless it clears the screen. The output is marked as starting here (OSC 133;C), before
        # the newline, so the blank row belongs to the output and not to the command. A command
        # that prints nothing leaves the cursor on that row, which then is the gap after it.
        _promptty_preexec() {
            'builtin' 'print' -rn -- $'\e[?25h'
            if [[ "${1%% *}" == (clear|reset) ]]; then
                _promptty_gap=0
            else
                _promptty_gap=1
                'builtin' 'print' -rn -- $'\e]133;C\a\n'
            fi
        }

        # zle is about to read a line: the prompt is ready. A theme that set its prompt after our
        # precmd is cleared here. Keys typed while a command ran (type-ahead) are dropped: they would
        # sit, invisible, in front of the next command from the bar. Then the cursor is hidden and
        # PrompTTY is told, with a directory report under a path only this integration uses,
        # followed by the real directory so the terminal's own record of it stays right. Last, the
        # line is marked as a prompt waiting for input (OSC 133): clearing it erased the mark the
        # prompt carried, and the terminal finds where each command starts from these marks.
        _promptty_line_init() {
            'builtin' 'local' REPLY
            _promptty_prompt
            'builtin' 'emulate' -L zsh -o no_aliases
            if [[ "$PROMPT" != "$REPLY" || -n "$RPROMPT" ]]; then
                PROMPT="$REPLY" RPROMPT=''
                'builtin' 'zle' reset-prompt
            fi
            'builtin' 'local' _promptty_c
            while 'builtin' 'read' -t 0 -k 1 -s _promptty_c 2>/dev/null; do :; done
            'builtin' 'print' -rn -- $'\e[?25l\e]7;kitty-shell-cwd://'"${HOST}/.promptty-ready${PWD}"$'\a\e]7;kitty-shell-cwd://'"${HOST}${PWD}"$'\a\e]133;P;k=i\a\e]133;B\a'
        }

        # Lists what only the shell knows (history file, PATH, aliases, functions, builtins, reserved
        # words, exported names) for the bar's coloring and completion. Only when it changed: the
        # app rereads the file whenever it is written. The alias and function names are compared
        # in full (a new alias of the same count), the rest by their count.
        _promptty_write_state() {
            'builtin' 'emulate' -L zsh -o no_aliases
            [[ -n "${PROMPTTY_STATE-}" ]] || return 0
            'builtin' 'zmodload' zsh/parameter 2>/dev/null
            'builtin' 'local' key="${HISTFILE-}"$'\n'"$PATH"$'\n'"${(j: :)${(@ok)aliases}}"$'\n'"${(j: :)${(@ok)functions}}"$'\n'"${#builtins} ${#reswords} ${#${(@k)parameters[(R)*export*]}}"
            [[ "$key" != "${_promptty_state_key-}" || ! -e "$PROMPTTY_STATE" ]] || return 0
            'builtin' 'typeset' -g _promptty_state_key="$key"
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
            # A history file of PrompTTY's instead of the one .zshrc set up (a driven debug run's):
            # a new history list on it, after forgetting the user's file so that zsh never writes
            # the list it read from there back to it on exit.
            if [[ -n "${PROMPTTY_HISTFILE-}" ]]; then
                'builtin' 'unset' 'HISTFILE'
                'builtin' 'fc' -p -- "$PROMPTTY_HISTFILE"
                'builtin' 'unset' 'PROMPTTY_HISTFILE'
            fi
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

    /// Whether `other` has the same `commandNames`, compared kind by kind rather than by merging
    /// thousands of names twice.
    public func hasSameCommandNames(as other: ShellStateFile?) -> Bool {
        guard let other else { return false }
        return aliases == other.aliases && functions == other.functions && builtins == other.builtins && reserved == other.reserved
    }

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
