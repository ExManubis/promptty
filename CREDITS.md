# Credits

## Program logos

The logos in `Sources/PrompTTYApp/ProgramLogos.xcassets` identify the program running in a pane.
Each logo is a trademark of its owner; PrompTTY shows them only to identify those programs.

- [Simple Icons](https://simpleicons.org) 16.35.0, CC0 1.0: all logos except the ones below.
- [LobeHub Icons](https://github.com/lobehub/lobe-icons) (`@lobehub/icons-static-svg` 1.95.1),
  MIT: Codex (`logo-codex`), GitHub Copilot (`logo-githubcopilot`), Amp (`logo-amp`),
  Goose (`logo-goose`), Kilo Code (`logo-kilocode`), Kiro (`logo-kiro`), Kimi (`logo-kimi`) and Pi (`logo-pi`).
- [btop](https://github.com/aristocratos/btop) (`Img/icon.svg`), Apache License 2.0: `logo-btop`,
  redrawn with each of its red stripes as a plain shape in place of the original's SVG pattern.
- [claudewitz](https://github.com/ExManubis/Claudewitz) (`assets/icon-c.svg`), MIT: `logo-claudewitz`, its
  pixel C cropped to the glyph and its shadow, on the tile's purple square.

## Engine

- [Ghostty](https://github.com/ghostty-org/ghostty), MIT: libghostty, built from source with
  PrompTTY's patches (`Engine/patches`). Some of its shell integration scripts derive from Kitty's
  and are GPL-3.0 (`Engine/licenses/GPL-3.0.txt`, shipped beside them).
- [libghostty-spm](https://github.com/sethdeckard/libghostty-spm), MIT, Copyright (c) 2026 Seth
  Deckard: `Engine/patches/0001-surface-read-text-format.patch`, ported to the current Ghostty.
