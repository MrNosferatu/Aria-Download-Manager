"""Floating our windows on niri and Hyprland, against fake niri / hyprctl binaries.

    python3 tests/test_compositor.py
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from aria_download_manager import compositor  # noqa: E402
from tests.harness import check, summary  # noqa: E402

FAKE = """#!/bin/sh
# Lists the windows in $FAKE_WINDOWS for a list command, logs anything else.
case "$*" in
  "msg -j windows"|"-j clients") cat "$FAKE_WINDOWS" ;;
  *) echo "$*" >> "$FAKE_LOG" ;;
esac
"""


def install(bin_dir: Path, name: str) -> None:
    path = bin_dir / name
    path.write_text(FAKE)
    path.chmod(0o755)


async def run(tmp: Path) -> None:
    windows = tmp / "windows.json"
    log = tmp / "log"
    os.environ["FAKE_WINDOWS"] = str(windows)
    os.environ["FAKE_LOG"] = str(log)
    compositor.FIND_TIMEOUT = 0.5

    def calls() -> list[str]:
        return log.read_text().splitlines() if log.exists() else []

    print("\nniri")
    niri_bin = tmp / "niri-bin"
    niri_bin.mkdir()
    install(niri_bin, "niri")
    os.environ["PATH"] = f"{niri_bin}:/usr/bin:/bin"
    os.environ["NIRI_SOCKET"] = str(tmp / "niri.sock")
    windows.write_text(json.dumps([
        {"id": 3, "title": "New download — Aria Download Manager — Mozilla Firefox", "is_floating": True},
        {"id": 7, "title": "New download — Aria Download Manager — Mozilla Firefox", "is_floating": False},
        {"id": 9, "title": "Aria Download Manager — Mozilla Firefox", "is_floating": False},
    ]))
    done = await compositor.float_window("New download — Aria Download Manager", 640, 700)
    check("niri floats the new (tiled) dialog, not the one already floating",
          done == "niri" and calls()[0] == "msg action move-window-to-floating --id 7", str(calls()))
    check("and sizes and centres it",
          "msg action set-window-width --id 7 640" in calls() and "msg action center-window --id 7" in calls(),
          str(calls()))
    log.unlink()
    done = await compositor.float_window("Aria Download Manager", exact=True)
    check("an exact title never catches a browser showing a page of that name", done == "" and not calls(),
          str(calls()))
    windows.write_text(json.dumps([{"id": 2, "title": "Aria Download Manager", "is_floating": False}]))
    done = await compositor.float_window("Aria Download Manager", exact=True)
    check("the DankBar window is floated", done == "niri"
          and calls() == ["msg action move-window-to-floating --id 2", "msg action center-window --id 2"],
          str(calls()))

    print("\nHyprland")
    log.unlink()
    del os.environ["NIRI_SOCKET"]
    hypr_bin = tmp / "hypr-bin"
    hypr_bin.mkdir()
    install(hypr_bin, "hyprctl")
    os.environ["PATH"] = f"{hypr_bin}:/usr/bin:/bin"
    os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = "abc"
    windows.write_text(json.dumps([
        {"address": "0x55", "title": "New download — Aria Download Manager - Chromium", "floating": False}]))
    done = await compositor.float_window("New download — Aria Download Manager", 640, 700)
    check("Hyprland floats, sizes and centres it", done == "hyprland" and calls() == [
        "dispatch setfloating address:0x55",
        "dispatch resizewindowpixel exact 640 700,address:0x55",
        "dispatch focuswindow address:0x55",
        "dispatch centerwindow"], str(calls()))

    print("\nneither")
    log.unlink()
    del os.environ["HYPRLAND_INSTANCE_SIGNATURE"]
    os.environ["XDG_RUNTIME_DIR"] = str(tmp / "empty-runtime")
    done = await compositor.float_window("New download — Aria Download Manager")
    check("no compositor running: nothing happens", done == "" and not calls(), str(calls()))


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="aria-compositor-"))
    try:
        asyncio.run(run(tmp))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return summary()


if __name__ == "__main__":
    sys.exit(main())
