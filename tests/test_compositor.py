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
        {"id": 7, "title": "Extension: (Aria Download Manager) - New download — Aria Download Manager"
                           " — Mozilla Firefox", "is_floating": False},
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

    print("\nniri: the maximize button")
    log.unlink()
    windows.write_text(json.dumps([{"id": 4, "title": "Aria Download Manager", "is_floating": True,
                                    "layout": {"window_size": [1120, 820]}}]))
    done = await compositor.toggle_maximize("Aria Download Manager")
    check("a floating window is sized to the working area and moved to its corner",
          done == {"by": "niri", "maximized": True} and calls() == [
              "msg action set-window-width --id 4 100%",
              "msg action set-window-height --id 4 100%",
              "msg action move-floating-window --id 4 -x 0 -y 0"], f"{done} {calls()}")
    log.unlink()
    done = await compositor.toggle_maximize("Aria Download Manager")
    check("the second press puts back the size it had",
          done == {"by": "niri", "maximized": False} and calls() == [
              "msg action set-window-width --id 4 1120",
              "msg action set-window-height --id 4 820",
              "msg action center-window --id 4"], f"{done} {calls()}")
    log.unlink()
    windows.write_text(json.dumps([{"id": 5, "title": "Aria Download Manager", "is_floating": False}]))
    done = await compositor.toggle_maximize("Aria Download Manager")
    check("a tiled one is maximized to the edges",
          done["by"] == "niri" and calls() == ["msg action maximize-window-to-edges --id 5"], str(calls()))
    log.unlink()
    windows.write_text(json.dumps([{"id": 6, "title": "Aria Download Manager — Mozilla Firefox",
                                    "is_floating": True}]))
    done = await compositor.toggle_maximize("Aria Download Manager")
    check("a browser page of that name is never touched", not calls(), str(calls()))

    print("\nHyprland")
    if log.exists():
        log.unlink()
    del os.environ["NIRI_SOCKET"]
    # A real niri may be on /usr/bin with its socket in the runtime directory:
    # hide the socket, or the checks below would move the real window.
    os.environ["XDG_RUNTIME_DIR"] = str(tmp / "empty-runtime")
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
    log.unlink()
    windows.write_text(json.dumps([{"address": "0x66", "title": "Aria Download Manager", "fullscreen": 0}]))
    done = await compositor.toggle_maximize("Aria Download Manager")
    check("Hyprland maximizes it", done == {"by": "hyprland", "maximized": True} and calls() == [
        "dispatch focuswindow address:0x66", "dispatch fullscreen 1"], f"{done} {calls()}")

    print("\nneither")
    log.unlink()
    del os.environ["HYPRLAND_INSTANCE_SIGNATURE"]
    os.environ["XDG_RUNTIME_DIR"] = str(tmp / "empty-runtime")
    done = await compositor.float_window("New download — Aria Download Manager")
    check("no compositor running: nothing happens", done == "" and not calls(), str(calls()))


async def desktop(tmp: Path) -> None:
    print("\nfolder chooser")
    from aria_download_manager import files

    bin_dir = tmp / "picker-bin"
    bin_dir.mkdir()
    chosen = tmp / "Chosen Folder"
    chosen.mkdir()
    (bin_dir / "zenity").write_text(f'#!/bin/sh\necho "$*" > "{tmp}/zenity-args"\necho "{chosen}"\n')
    (bin_dir / "zenity").chmod(0o755)
    os.environ["PATH"] = f"{bin_dir}:/usr/bin:/bin"
    check("a picker is found", compositor.picker_available())
    picked = await compositor.pick_folder(str(tmp))
    check("zenity's choice comes back", picked == str(chosen), str(picked))
    check("it starts in the given folder", f"--filename={tmp}/" in (tmp / "zenity-args").read_text())
    (bin_dir / "zenity").write_text("#!/bin/sh\nexit 1\n")
    check("cancelled: empty", await compositor.pick_folder(str(tmp)) == "")
    (bin_dir / "zenity").unlink()
    os.environ["PATH"] = "/nonexistent"
    check("no picker at all: None", await compositor.pick_folder(str(tmp)) is None)
    os.environ["PATH"] = "/usr/bin:/bin"

    print("\na web page saved as a file")
    page = tmp / "driver.exe"
    page.write_bytes(b"\n <!DOCTYPE html><html><body>verify you're human</body></html>")
    check("an .exe that is a page is caught",
          files.expects_binary(str(page)) and files.starts_like_html(str(page)) is True)
    real = tmp / "real.exe"
    real.write_bytes(b"MZ\x90\x00" + b"\x00" * 100)
    check("a real .exe is left alone", files.starts_like_html(str(real)) is False)
    blank = tmp / "pre.iso"
    blank.write_bytes(b"\0" * 4096)
    check("preallocated, not written yet: undecided", files.starts_like_html(str(blank)) is None)
    check("a page saved as .html is expected",
          not files.expects_binary(str(tmp / "index.html")) and not files.expects_binary(str(tmp / "noext")))


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="aria-compositor-"))
    try:
        asyncio.run(run(tmp))
        asyncio.run(desktop(tmp))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return summary()


if __name__ == "__main__":
    sys.exit(main())
