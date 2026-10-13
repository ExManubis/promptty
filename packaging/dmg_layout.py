#!/usr/bin/env python3
"""Writes the DMG window's Finder layout into the mounted image's .DS_Store.

Finder AppleScript on macOS 26 does not persist a window's background picture or icon size
on APFS volumes, so the records dmgbuild writes are written directly instead: a
volume-relative alias to the background (backgroundType 2) and no bookmark, which Finder
treats as stale and then drops the picture. (From the first PrompTTY's
script/macos/apply_dmg_finder_layout.py.)

Run with the ds_store and mac_alias packages, e.g.:
  uv run --with ds_store --with mac_alias python3 packaging/dmg_layout.py --mount-dir … --app-name PrompTTY.app --background .background/background.tiff
"""

from __future__ import annotations

import argparse
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mount-dir", required=True, type=Path)
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--background", required=True, help="path inside the mounted volume")
    # The picture is 640×400 points; the window's bounds include the ~28 pt title bar.
    parser.add_argument("--window-width", type=int, default=640)
    parser.add_argument("--window-height", type=int, default=428)
    parser.add_argument("--icon-size", type=int, default=128)
    # Centered in the picture's two frames, left and right of its arrow.
    parser.add_argument("--app-x", type=int, default=160)
    parser.add_argument("--app-y", type=int, default=200)
    parser.add_argument("--applications-x", type=int, default=480)
    parser.add_argument("--applications-y", type=int, default=200)
    args = parser.parse_args()

    mount_dir = args.mount_dir.resolve()
    background = (mount_dir / args.background).resolve()
    if not background.is_file():
        raise SystemExit(f"DMG background not found: {background}")

    bounds = f"{{{{200, 120}}, {{{args.window_width}, {args.window_height}}}}}"
    window = {
        "ShowStatusBar": False,
        "WindowBounds": bounds,
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
        "ShowTabView": False,
        "ShowToolbar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
    }
    # Finder does not stretch the picture: a larger window (the DMG opened as a tab) is
    # filled with the art's own charcoal instead of white.
    charcoal = 25 / 255.0
    icons = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundColorRed": charcoal,
        "backgroundColorGreen": charcoal,
        "backgroundColorBlue": 28 / 255.0,
        "backgroundImageAlias": Alias.for_file(str(background)).to_bytes(),
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showIconPreview": True,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": 12.0,
        "iconSize": float(args.icon_size),
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }

    with DSStore.open(str(mount_dir / ".DS_Store"), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = window
        store["."]["icvp"] = icons
        store["."]["icvl"] = (b"type", b"icnv")
        store[args.app_name]["Iloc"] = (args.app_x, args.app_y)
        store["Applications"]["Iloc"] = (args.applications_x, args.applications_y)


if __name__ == "__main__":
    main()
