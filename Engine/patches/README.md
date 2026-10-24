# Engine patches

PrompTTY's changes to Ghostty, applied by `script/build-engine` to the pinned Ghostty source
(`.build/engine/ghostty`) for the duration of a build and reverted when it exits, in lexical
order: a patch may build on an earlier one.

- `0001-surface-read-text-format`: `ghostty_surface_read_text_format`, a selection's text with
  its colors and styles as escape sequences. From
  [libghostty-spm](https://github.com/sethdeckard/libghostty-spm) (MIT, © 2026 Seth Deckard),
  which PrompTTY built from until Ghostty's move to Zig 0.16.
- `0003-command-blocks`: `ghostty_surface_blocks` and `ghostty_surface_block_text`, the commands
  the shell ran and their output, from shell integration's prompt marks.
- `0004-program-status`: a program's status reports (OSC 7501, which Ghostty parses but its app
  ignores) go to the apprt as `GHOSTTY_ACTION_PROGRAM_STATUS`, decoded; the support query
  `OSC 7501 ; ?` is answered, and a full reset clears every record.
- `0005-pty-tap`: `ghostty_surface_set_output_tap`, a callback given each chunk of a surface's
  pty output as read, before it is parsed (for mirroring a pane). Termio's `processOutput` calls
  it on the read thread with the terminal locked, so a reader of the screen sees it before or
  after a chunk, never halfway; setting it takes the same lock, so once it is turned off (NULL)
  no call is running or follows. Without a tap a chunk costs one null check.
- `0006-host-fed-surface`: a surface whose program runs elsewhere, for the iPhone (iOS can't start
  one). termio gets a second backend, `host` (`src/termio/Host.zig`), beside `exec`: it spawns
  nothing and has no pty. Setting `io_write_cb` on `ghostty_surface_config_s` makes a surface use
  it: `ghostty_surface_feed(surface, bytes, len)` puts the program's output on screen (through
  `Termio.processOutput`, as a pty read would), and everything the terminal writes to the program
  (keys, paste, mouse and focus reports, replies to queries, size reports; `\r` as `\r\n` in
  linefeed mode) goes to `io_write_cb`, and each new grid to `io_resize_cb`. Both run on the
  surface's IO thread, sometimes with its terminal locked: they copy and return, never calling
  back into the surface. Surfaces made without it start a command on a pty as before. The patch
  also puts back the iOS slices upstream dropped from the xcframework (7a171895d; the runtime
  code was kept) as `-Dxcframework-target=ios`: macOS native plus iOS and the iOS simulator,
  built by `script/build-engine --ios`. With them, Aro needs `-fblocks` for the iOS SDK's
  CoreGraphics headers (it enables blocks for macOS only), and the default DPI is 72 on iOS as on
  macOS, so a font size is the same size on both (it was 96, a third larger). Zig tests:
  `zig build test -Dtest-filter=Host:`.
- `0007-vt-snapshot`: `ghostty_surface_read_vt_snapshot`, the terminal's state as VT bytes that
  rebuild it in a fresh terminal of the same size (scrollback up to a limit, the screen, cursor,
  modes, the alternate screen with the primary behind it, changed palette entries), ending with
  the escape sequence or UTF-8 character the pty output stopped in the middle of (Termio's stream
  now keeps it: upstream's continuation tracking, up to 16 KiB). Taken with the terminal locked,
  and a callback there gets the grid size: with the output tap (0005) a mirror knows exactly
  which chunks the snapshot holds. Its Zig tests replay a snapshot into a second terminal.

## Authoring a patch

Edit `.build/engine/ghostty` with the earlier patches applied, capture the diff, then restore it:

```sh
# ...edit files under .build/engine/ghostty...
git -C .build/engine/ghostty add -A
git -C .build/engine/ghostty diff --cached > Engine/patches/0004-your-change.patch
git -C .build/engine/ghostty reset --hard
```

Stage first: a plain `git diff` skips untracked files. The output is a diff for `git apply`, not
`git format-patch`. A patch that adds a C export PrompTTY needs adds it to `REQUIRED_SYMBOLS` in
`script/build-engine`.

## On a Ghostty pin bump

Move `PIN` in `script/build-engine` and run `script/build-engine --force`. It fails with the name
of the first patch that no longer applies. Redo that change against the new source (committing
each patch in a scratch branch and `git apply --3way` the next one helps), regenerate the patch
files from the commits, and run the patches' Zig tests: `zig build test -Dtest-filter=blocks:`
`-Dtest-filter=output_tap:` and `-Dtest-filter=vt_snapshot:` in `.build/engine/ghostty`. Delete a patch once upstream has an
equivalent: `0002`, which parsed each synchronized update (mode 2026) whole so Claude Code
rendered smoothly, went when Ghostty's pipelined pty reader made it render at 60 fps without it.
