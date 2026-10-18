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
in `.build/engine/ghostty`. Delete a patch once upstream has an equivalent: `0002`, which parsed
each synchronized update (mode 2026) whole so Claude Code rendered smoothly, went when Ghostty's
pipelined pty reader made it render at 60 fps without it.
