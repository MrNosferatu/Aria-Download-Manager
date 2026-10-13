"""Float our own windows on a tiling compositor, without the user writing rules.

A Wayland window cannot ask to float; that is the compositor's call. So right
after one of ours opens (the extension's download dialog, the DankBar widget's
detached window) the manager finds it by title and asks the compositor itself:
niri through ``niri msg``, Hyprland through ``hyprctl``. Anything else, or a
compositor that is not running, is a quiet no-op.

The manager often runs as a systemd user service, whose environment may lack
NIRI_SOCKET / HYPRLAND_INSTANCE_SIGNATURE, so both are found in the runtime
directory when they are missing.
"""

from __future__ import annotations

import asyncio
import glob
import json
import os
import re
import shutil

#: How long to wait for the window to show up after the request.
FIND_TIMEOUT = 3.0


def _runtime_dir() -> str:
    return os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"


def niri_env() -> dict[str, str] | None:
    if not shutil.which("niri"):
        return None
    env = dict(os.environ)
    if not env.get("NIRI_SOCKET"):
        sockets = sorted(glob.glob(os.path.join(_runtime_dir(), "niri.*.sock")), key=os.path.getmtime)
        if not sockets:
            return None
        env["NIRI_SOCKET"] = sockets[-1]
    return env


def hyprland_env() -> dict[str, str] | None:
    if not shutil.which("hyprctl"):
        return None
    env = dict(os.environ)
    if not env.get("HYPRLAND_INSTANCE_SIGNATURE"):
        instances = sorted(glob.glob(os.path.join(_runtime_dir(), "hypr", "*", ".socket.sock")),
                           key=os.path.getmtime)
        if not instances:
            return None
        env["HYPRLAND_INSTANCE_SIGNATURE"] = os.path.basename(os.path.dirname(instances[-1]))
    return env


async def _run(argv: list[str], env: dict[str, str]) -> tuple[int, str]:
    proc = await asyncio.create_subprocess_exec(
        *argv, env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), 5)
    except asyncio.TimeoutError:
        proc.kill()
        return -1, ""
    return proc.returncode or 0, out.decode("utf-8", "replace")


async def _find(list_argv, env, title: re.Pattern, key: str):
    """Poll the compositor's window list until a tiled window's title matches."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + FIND_TIMEOUT
    while True:
        code, out = await _run(list_argv, env)
        if code == 0:
            try:
                matches = [w for w in json.loads(out or "[]") if title.search(str(w.get(key) or ""))]
            except (ValueError, AttributeError):
                return None
            # Only a tiled match needs anything done. Several dialogs share a
            # title, and the one still tiled is the new one; if every match
            # floats already (a rule of the user's), there is nothing to do.
            fresh = [w for w in matches if not (w.get("is_floating") or w.get("floating"))]
            if fresh:
                return fresh[-1]
        if loop.time() >= deadline:
            return None
        await asyncio.sleep(0.15)


async def float_window(title_prefix: str, width: int = 0, height: int = 0,
                       exact: bool = False) -> str:
    """Float (and size, and centre) the newest tiled window whose title starts so.

    ``exact`` matches the whole title: a browser window showing a page of the
    same name must not be caught by a prefix. Returns which compositor did it,
    or "" when none could.
    """
    if not title_prefix.strip():
        return ""
    title = re.compile("^" + re.escape(title_prefix.strip()) + ("$" if exact else ""))

    env = niri_env()
    if env:
        window = await _find(["niri", "msg", "-j", "windows"], env, title, "title")
        if window and window.get("id") is not None:
            wid = str(window["id"])
            await _run(["niri", "msg", "action", "move-window-to-floating", "--id", wid], env)
            if width and height:
                await _run(["niri", "msg", "action", "set-window-width", "--id", wid, str(width)], env)
                await _run(["niri", "msg", "action", "set-window-height", "--id", wid, str(height)], env)
            await _run(["niri", "msg", "action", "center-window", "--id", wid], env)
            return "niri"

    env = hyprland_env()
    if env:
        window = await _find(["hyprctl", "-j", "clients"], env, title, "title")
        if window and window.get("address"):
            target = f"address:{window['address']}"
            await _run(["hyprctl", "dispatch", "setfloating", target], env)
            if width and height:
                await _run(["hyprctl", "dispatch", "resizewindowpixel", f"exact {width} {height},{target}"], env)
            await _run(["hyprctl", "dispatch", "focuswindow", target], env)
            await _run(["hyprctl", "dispatch", "centerwindow"], env)
            return "hyprland"
    return ""
