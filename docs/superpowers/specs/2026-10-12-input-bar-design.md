# PrompTTY input bar — design

Date: 2026-10-12 · Branch: `input-bar` · Status: approved in conversation

## Goal

A Warp-style command input for zsh panes. While the shell is idle, each pane shows a native
input bar at the bottom of its card, with a header above it in place of the shell prompt. While
anything else runs (`nvim`, `ssh`, `sudo`, REPLs), the bar is gone and every key goes to the
terminal exactly as today.

## Decisions (from the conversation)

- The bar **replaces** the shell prompt; the shell's own prompt is hidden.
- The header is **native**: directory, git branch + dirty dot, last exit code and duration.
- **zsh only.** Other shells get today's plain terminal.
- Editor features: **history** (↑/↓), **ghost-text suggestions**, **Tab completion**, **syntax
  coloring**. No fuzzy ⌃R/⌃T pickers.
- **Vi mode** in the bar (the user runs `bindkey -v`).
- Commands appear in scrollback **bare** (no marker before them).
- Injection: **PrompTTY's own zsh integration via `ZDOTDIR`** (option 1). No settings.

## Spike results (2026-10-12, verified in the running app)

- A per-surface `ZDOTDIR` (libghostty `env_vars`) survives Ghostty's own zsh injection: Ghostty
  saves it as `GHOSTTY_ZSH_ZDOTDIR`, restores it, and sources `$ZDOTDIR/.zshenv`, i.e. ours.
- Emptying `PROMPT`/`RPROMPT` from a precmd hook registered after `.zshrc` hides starship.
- An OSC 7 (`kitty-shell-cwd://`) printed from our precmd arrives as a `pwd` action at **every**
  prompt, including the first, even when the directory did not change.
- `COMMAND_FINISHED` arrives after each command with exit code and duration (ns).
- `ghostty_surface_foreground_pid` returns the shell's pid at a prompt and the child's while a
  command runs.

## 1. zsh integration and pane states

**Injection.** When the user's login shell (`getpwuid(getuid())->pw_shell`) is zsh, each new
surface gets `ZDOTDIR=<integration dir>` and `PROMPTTY_STATE=<per-pane state file>`. The
integration dir lives in `~/Library/Application Support/PrompTTY/shell/zsh/` and is (re)written
at launch from strings compiled into the app, so its path has no bundle quirks and it always
matches the running build.

Our `.zshenv`:
1. Unsets `ZDOTDIR` (zsh then reads the user's `.zshrc` etc. from `$HOME`, exactly as without us).
2. Sources `~/.zshenv` if readable.
3. If interactive, registers a one-shot precmd `_promptty_init`, which therefore runs after
   `.zshrc`, at the first prompt.

`_promptty_init` (first prompt only):
- Puts `_promptty_precmd` first in `precmd_functions` and `_promptty_preexec` in `preexec_functions`.
- `unsetopt HIST_VERIFY`: the bar cannot show a re-loaded line, so `!!` runs directly.
- Adds a `line-init` zle hook (via `add-zle-hook-widget`) that empties `BUFFER`: keys typed while
  a command ran (type-ahead) would otherwise sit invisibly in front of the next command.
- Writes the state file, one `<kind> <value>` per line: `histfile <path>` (when `HISTFILE` is set),
  `path <$PATH>` (the shell's, which includes Homebrew; a GUI app's own `PATH` does not),
  `alias|function|builtin|reserved <name>` per name, and `export <name>` per exported parameter.

`_promptty_precmd` (every prompt): `PROMPT=''`, `RPROMPT=''`, hide the cursor (`\e[?25l`), report
the directory with OSC 7. `_promptty_preexec`: show the cursor (`\e[?25h`).

**Pane states** (a pure state machine in `CommandEditing`, driven by the controller):
- `starting`: plain terminal. Every zsh pane begins here; non-zsh panes never leave it.
- `idle`: bar and header shown; the bar has focus.
- `running`: no bar; keys go to the terminal.

Events and transitions:
- `promptReady(pid)` — a `pwd` action while the foreground pid equals the shell's pid. The shell's
  pid is the foreground pid seen with the first `pwd` (precmd runs in the shell itself).
  `starting|running → idle`. A later `promptReady` while idle is ignored.
- `submitted` — the user pressed ⏎ in the bar: `idle → running`.
- `commandFinished(code, duration)` — records the header's exit status; does not change state
  (the following `promptReady` does).
- `foregroundChanged(pid)` — from a 250 ms poll while `idle`: a foreground pid other than the
  shell's (`fg` of a job, a program started by a hook) means `idle → running`.
- A pane that never becomes ready stays a plain terminal: a broken `.zshrc` cannot lock anyone out.

**Header data.** Directory from `pwd`. Git: on entering `idle`, a background
`git -C <dir> status --porcelain=v2 --branch` (1 s timeout) gives branch (or short sha when
detached) and dirty (any entry line). Exit code and duration from `commandFinished`; duration shown
when ≥ 1 s.

## 2. The bar, the header, and running a command

**Layout.** Inside the pane card, below the terminal: a hairline, the header row (SF Pro 11 pt,
secondary color; `folder` + directory abbreviated with `~`, `arrow.triangle.branch` + branch + a
dot when dirty, `checkmark`/`xmark` + exit code, duration), then the input in the terminal's font
family and size, 1–8 lines then scrolling. The bar uses the card's panel color.

**Running a command.**
1. ⏎: the state goes `running`, the bar leaves the layout (the terminal grows to the full card)
   but stays drawn on top for 150 ms, then fades out over 120 ms. A command that finishes within
   150 ms never makes the bar blink.
2. The command is sent once the terminal has taken its new size (the surface reports its size
   change) or after 50 ms, whichever comes first; programs start at their real size.
3. The text goes to zsh as a paste (`ghostty_surface_text`, bracketed because zle enables
   bracketed paste), followed by a Return sent as key input. zsh runs it: history, aliases, `$?`
   all behave as before.
4. Back at `idle`, the bar rejoins the layout and the terminal shrinks above it while the shell is
   idle; Ghostty keeps the bottom rows and pushes the top into scrollback.

**Keys in the bar.** ⏎ runs (on an empty bar: sends Return, a fresh prompt). ⇧⏎ inserts a newline.
⌃C clears the bar. ⌃D on an empty bar sends EOF (`\x04`). ⌃L sends `\x0c` (zle clears the
screen). ⌃U deletes to the line start. ⌘ shortcuts go to the menus as everywhere else.

**Focus and mouse.** The pane's focus target is the bar while `idle` and the terminal otherwise;
all existing focus paths (selecting a pane or tab, window key, re-hosting) use it. Clicks and
drags in the terminal while `idle` still select text there, and ⌘C copies that selection; the
first typed key moves focus back to the bar and is delivered there.

## 3. Editing

**Vi mode.** Starts in insert mode with native macOS editing. Esc → normal mode (cursor moves
back one, as in vi). Cursor: bar in insert, block in normal. Normal mode:
- motions `h l w b e W B E 0 ^ $`, `j`/`k` (move between lines; on the first/last line they walk
  history, as zsh vi mode does), counts (`3w`);
- `x X r ~ D C s S`, `i a I A o O`, `u` (undo), `.` is out of scope;
- operators `d c y` with any motion above and with `iw aw`, doubled (`dd cc yy`);
- `p P` from an unnamed vi register (yank and delete fill it).

**History.** Parsed from the `histfile` the shell reported (none reported: session history only): extended
format `: <ts>:<dur>;<cmd>`, plain lines, multi-line entries (lines ending in `\` continue), and
zsh's metafied bytes (`0x83` marks a byte xor `0x20`). Newest first, duplicates removed (newest
kept), plus commands sent this session. Reloaded when the file's modification date changes. ↑/↓
(insert mode, when the caret is on the first/last line) and `k`/`j` (normal mode) walk it; the
text being edited is restored when walking back down past the newest entry.

**Ghost text.** The newest history entry that starts with the current text (and is longer) is shown
in a dim color after the caret when the caret is at the end. → or End (at the end) or ⌃Space
accepts it all; ⌥→ accepts one word.

**Syntax coloring.** A zsh-aware tokenizer splits the text into words, quotes (`'…'`, `"…"`,
`$'…'`), variables (`$x`, `${…}`), operators (`| || & && ; ;; > >> < << 2> &>` and parentheses),
comments (`#` at a word start), with command position after operators and at the start. Colors
from the terminal theme's ANSI palette: known command green, unknown command red, flags cyan,
strings yellow, variables blue, operators magenta, comments bright black. "Known" = an executable
in a directory of the shell's `path` or a name in the state file.

**Tab completion.** First word: known command names. `$` prefix: the shell's exported names.
After `git`: subcommands; after `git checkout|switch|merge|rebase|branch -d|-D`: local branch names
(`git for-each-ref refs/heads`). Otherwise: paths relative to the pane directory (with `~`
expanded, directories suffixed `/`, hidden files only when the prefix starts with `.`). One match
is inserted; several insert their common prefix and open a popup at the caret: Tab/↓ next,
⇧Tab/↑ previous, ⏎ accept, Esc closes (a second Esc enters normal mode); typing filters.

## 4. Structure

- New SwiftPM library **`CommandEditing`** (no AppKit) + `CommandEditingTests`: `EditBuffer`,
  `ViEngine`, `ZshHistory` (parser) + `HistoryNavigator`, `Autosuggester`, `CommandTokenizer`,
  `CompletionEngine` (file system, git and environment behind protocols), `GitStatus` (porcelain
  v2 parser), `ShellPaneState` (state machine), `ZshIntegration` (script text, installer, state
  file parser).
- **`GhosttyBridge`**: per-surface environment variables, `commandFinished` action, foreground pid,
  `sendInput` (raw key text), an `onSizeChange` callback, key forwarding hook for the idle bar.
- **App**: `PaneShell` (per pane: state, history, header model, timers), `CommandTextView`
  (`NSTextView` subclass driving `ViEngine`), `InputBarView` (SwiftUI header + hosted text view),
  `CompletionPopup`, focus routing in `TerminalWindowController`, theme colors.

## Testing

- Unit: vi commands (table-driven), history fixtures (extended, plain, multi-line, metafied,
  duplicates), tokenizer cases, completion with a fake file system and git, git status parsing,
  every state machine transition, the state file parser, integration script installation.
- End-to-end (debug driver): command runs and its output appears; header shows directory, branch,
  exit code; `nvim` hides the bar and receives keys; ⌃C clears; a non-zsh shell stays plain; a
  `.zshrc` that errors still reaches the bar; a failing integration (no ready signal) leaves a
  plain terminal.

## Out of scope

Fuzzy pickers, blocks (grouped command output), bash/fish, AI features, the vi `.` command,
visual mode, settings of any kind.
