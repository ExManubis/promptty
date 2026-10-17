<p align="center">
  <img src="docs/images/promptty-logo.png" alt="PrompTTY" />
</p>

<p align="center">
  A native macOS terminal for working alongside coding agents.<br>
  Built on <a href="https://ghostty.org">libghostty</a>, the engine behind Ghostty.
</p>

## What you get

- **A calm, native window.** A sidebar (or tab strip) with each pane in its own rounded card.
  The [Flexoki](https://github.com/kepano/flexoki) theme follows your system's light and dark
  mode, and every Ghostty theme is one click away.
- **Agents at a glance.** PrompTTY spots Claude Code, Codex, Amp, Cline and others running in
  a pane. Each tab shows whether its agent is working, waiting for permission or done, and you
  get a notification when it needs you.
- **New output, marked.** A tab that printed while you looked elsewhere gets a ring by its name
  until you open it (a `tail -f`, a log, a build).
- **Long commands tell you when they're done.** A command that ran 10 seconds or more in a tab you
  aren't looking at posts a notification with how it ended and how long it took (Settings › Tabs
  sets how long is long, or turns it off).
- **Remote hosts.** A tab running `ssh` shows the host it's connected to, and the command palette
  lists every host in `~/.ssh/config` to open in a new tab.
- **Dev servers at a glance.** A tab whose programs listen on a port shows it (`:3000`) under its
  name; click it to open `localhost:3000` in your browser.
- **A smarter prompt.** In zsh, an input bar replaces the shell prompt: history, suggestions,
  Tab completion, syntax coloring, vi mode and fuzzy history search (⌃R).
- **Command blocks.** Every command and its output is a block you can jump between, copy, copy
  as Markdown or rerun. ⌃⌘↑ jumps straight to the last failure. ⌘F finds anything in the
  scrollback, every match highlighted. Scrolled back while a command keeps printing, a pill says
  how many new lines are below; click it to jump down.
- **Pick up where you left off.** Quit and reopen PrompTTY: every tab comes back in its folder
  with what it printed before, colors included, above a fresh prompt (zsh).
- **Projects and pinned tabs.** Group tabs into projects. Pin a tab running `claude` or
  `npm run dev` and it comes back, still running, the next time you open PrompTTY.
- **Jump to a folder.** ⌘J lists the folders you work in, most used and most recent first:
  Return goes there, ⌘Return opens a new tab there.
- **Quick terminal.** ⌥↩ from any app drops a terminal down from the top of the screen; the
  same keys (or clicking elsewhere) put it away, its shell still running. Change the keys or turn
  it off in Settings › Keyboard.
- **Command palette.** ⌘K finds any tab in any window and runs any command by name, with its
  shortcut beside it. Save a command you run often from its block (the bookmark button) and it
  is in ⌘K by name: Return runs it here, ⌘Return in a new tab.
- **Splits.** Split right or down, drag to resize, zoom one pane to fill the tab. Each pane has a
  header with its program, title and folder; its buttons split, zoom and close, and dragging it
  moves the pane (Settings › Appearance › Pane headers). Name a pane
  ("server", "logs") with **Window › Label Pane…**; the label sits on the pane and is kept with
  the session.
- **Type into every pane at once.** ⌥⇧⌘I broadcasts what you type to all panes of a tab (handy
  for the same command on several servers); each pane wears an orange border while it's on.
- **Undo a closed tab.** ⇧⌘T brings back the last ten closed tabs, splits and folders included.
- **Safe by default.** ⌘-click opens links and `path:line:col`, but never runs programs.
  Programs must ask before using your clipboard, and password prompts get secure input.

## Install

Download the latest `.dmg` from [Releases](https://github.com/ExManubis/promptty/releases) and
drag PrompTTY to Applications. Requires an Apple silicon Mac with macOS 26.

## Script it

Every PrompTTY terminal has a `promptty` command, so scripts, editors and agents can drive the
app:

```sh
promptty ls                                # windows, tabs and panes (--json for scripts)
promptty split right -- npm run dev        # a pane beside this one, running the dev server
promptty new-tab --cwd ~/api -- make test  # a new tab
promptty -p logs send 'tail -f app.log' --enter
promptty -p logs capture                   # what that pane shows (--all: its scrollback too)
promptty label server                      # name this pane
promptty notify "Deploy done"
```

An agent can work in a pane beside it and read back exactly what its command did. Every command
run from the input bar (or started by `promptty`) has an id; `--json` hands it out:

```sh
promptty split right --label tests --json -- make test   # {"pane": "…", "block": "block:…"}
promptty wait -b <block> --timeout 600                    # exits with make's own status
promptty capture -b <block>                               # that command's output, nothing else
promptty -p tests send --enter --json make lint           # another command, another id
promptty ls --json                                        # each pane's recent commands and exit codes
```

`-p` names a pane by its label, its id or the end of its id; `-b` a command by its id or the end
of it. Panes set `TERM_PROGRAM=PrompTTY`. Exit status: 0 ok, 1 failed, 2 usage, 3 no such pane or
command (or more than one), 4 PrompTTY not reachable, 5 `wait` timed out. Turn it off in
**Settings › Tabs › Command line**.

## Connect your agents

PrompTTY can guess an agent's state from its screen, but it knows for sure with hooks:

- **Claude Code:** open **Settings › Agents › Install Claude Code Hooks…**. You see what will
  change before anything is written, and **Remove…** undoes it. Start a new Claude Code session
  afterwards.
- **Codex:** add the line shown in **Settings › Agents** to the top of `~/.codex/config.toml`.

The hooks send PrompTTY only what it needs to show state (never your prompts or tool input).
If you move PrompTTY.app, install the hooks again.

## Keys

PrompTTY only takes shortcuts with ⌘ (the quick terminal's ⌥↩ aside), so ⌃ and ⌥ combinations reach your programs (Neovim
included), and Option works as Alt. Every shortcut can be changed in **Settings › Keyboard**.

| Action | Keys |
|---|---|
| Command palette | ⌘K |
| Quick terminal, from any app | ⌥↩ |
| New window / close window | ⌘N / ⇧⌘W |
| New tab / close tab | ⌘T / ⌥⌘W |
| Reopen the last closed tab | ⇧⌘T |
| Go to a folder | ⌘J |
| Next / previous tab, go to tab 1–9 | ⇧⌘] / ⇧⌘[, ⌘1…⌘9 |
| Toggle sidebar / sidebar or strip | ⌘B / ⌃⌘S |
| Split right / split down | ⌘D / ⇧⌘D |
| Close pane | ⌘W |
| Move focus between panes | ⌥⌘← ↑ → ↓ (or ⌥H J K L) |
| Equalize / zoom panes | ⌃⌘= / ⇧⌘↩ |
| Broadcast input to all panes of the tab | ⌥⇧⌘I |
| Select previous / next command | ⌘↑ / ⌘↓ |
| Select previous / next failed command | ⌃⌘↑ / ⌃⌘↓ |
| Clear the screen | ⌥⌘K |
| Copy the command's output / the command | ⌥⌘C / ⇧⌘C |
| Rerun the selected command | ⇧⌘R |
| Find in the scrollback / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Find the selected text | ⌘E |
| Search history | ⌃R |

## Settings

Everything lives in **PrompTTY › Settings…** (⌘,) and applies immediately: fonts, themes,
cursor, sidebar or tab strip, session restore, clipboard access, shortcuts and agent hooks.
PrompTTY keeps its own settings and does not read your Ghostty config.

## Contributing

Build instructions, the source layout and how the agent hooks work are in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Third-party logos are credited in
[CREDITS.md](CREDITS.md).
