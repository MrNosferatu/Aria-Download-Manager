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


async def float_window(title_part: str, width: int = 0, height: int = 0,
                       exact: bool = False) -> str:
    """Float (and size, and centre) the newest tiled window whose title has this.

    Browsers wrap a page's title (Firefox: "Extension: (Name) - <title> —
    Mozilla Firefox"), so by default the text may sit anywhere in it. ``exact``
    matches the whole title instead, for a window whose title is ours alone: a
    browser showing a page of the same name must not be caught. Returns which
    compositor did it, or "" when none could.
    """
    if not title_part.strip():
        return ""
    escaped = re.escape(title_part.strip())
    title = re.compile(f"^{escaped}$" if exact else escaped)

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


async def resize_window(title_part: str, width: int, height: int, exact: bool = True) -> str:
    """Resize the newest window with this title, floating or not: a dialog
    fitting its height to what it shows. Returns which compositor did it."""
    if not title_part.strip() or width <= 0 or height <= 0:
        return ""
    escaped = re.escape(title_part.strip())
    title = re.compile(f"^{escaped}$" if exact else escaped)

    async def newest(list_argv, env):
        code, out = await _run(list_argv, env)
        try:
            matches = [w for w in json.loads(out or "[]") if title.search(str(w.get("title") or ""))] if code == 0 else []
        except (ValueError, AttributeError):
            return None
        return matches[-1] if matches else None

    env = niri_env()
    if env:
        window = await newest(["niri", "msg", "-j", "windows"], env)
        if window and window.get("id") is not None:
            wid = str(window["id"])
            await _run(["niri", "msg", "action", "set-window-width", "--id", wid, str(width)], env)
            await _run(["niri", "msg", "action", "set-window-height", "--id", wid, str(height)], env)
            return "niri"
    env = hyprland_env()
    if env:
        window = await newest(["hyprctl", "-j", "clients"], env)
        if window and window.get("address"):
            await _run(["hyprctl", "dispatch", "resizewindowpixel",
                        f"exact {width} {height},address:{window['address']}"], env)
            return "hyprland"
    return ""


#: The widths the DankBar window's column can open at, tiled.
COLUMN_WIDTHS = {"half": "50%", "two-thirds": "66.667%", "full": "100%"}


async def size_column(title_part: str, width: str, exact: bool = True) -> dict:
    """Give a newly tiled window's column a width: half, two thirds or full.

    For the DankBar window set to open tiled. niri sizes the window's column
    (set-window-width works on a tiled window by its id, nothing focused).
    Hyprland has no columns: there only "full" does anything, and the window
    is maximized. Returns which compositor did it ("" for none) and whether
    the window ended up maximized.
    """
    value = COLUMN_WIDTHS.get(str(width or ""))
    if not value or not title_part.strip():
        return {"by": "", "maximized": False}
    escaped = re.escape(title_part.strip())
    title = re.compile(f"^{escaped}$" if exact else escaped)

    env = niri_env()
    if env:
        window = await _find(["niri", "msg", "-j", "windows"], env, title, "title")
        if window and window.get("id") is not None:
            await _run(["niri", "msg", "action", "set-window-width", "--id", str(window["id"]), value], env)
            return {"by": "niri", "maximized": False}

    env = hyprland_env()
    if env and width == "full":
        window = await _find(["hyprctl", "-j", "clients"], env, title, "title")
        if window and window.get("address"):
            await _run(["hyprctl", "dispatch", "focuswindow", f"address:{window['address']}"], env)
            await _run(["hyprctl", "dispatch", "fullscreen", "1"], env)
            return {"by": "hyprland", "maximized": True}
    return {"by": "", "maximized": False}


#: niri window id -> (width, height, position in the workspace view or None)
#: it had before we filled the screen with it.
_unfilled: dict[int, tuple[int, int, list | None]] = {}


async def _niri_window(env: dict[str, str], wid: int) -> dict | None:
    code, out = await _run(["niri", "msg", "-j", "windows"], env)
    try:
        return next((w for w in json.loads(out or "[]") if w.get("id") == wid), None) if code == 0 else None
    except (ValueError, AttributeError):
        return None


async def toggle_maximize(title_part: str, exact: bool = True) -> dict:
    """Fill the screen with our window, or put it back; for its maximize button.

    A floating window's own maximize request is ignored by niri, and the
    DankBar window is always floating there, so the manager does it the way
    niri maximizes any window: into the tiled layout, its column maximized,
    with the gaps and border every other maximized window has. The size it
    had is remembered, and the way back floats it again at that size. A
    window already tiled just has its column maximized; Hyprland gets its
    maximize (fullscreen mode 1). Returns which compositor did it ("" for
    none: the caller falls back to the plain request) and whether the window
    now fills the screen.
    """
    escaped = re.escape(title_part.strip())
    title = re.compile(f"^{escaped}$" if exact else escaped)

    env = niri_env()
    if env:
        code, out = await _run(["niri", "msg", "-j", "windows"], env)
        try:
            matches = [w for w in json.loads(out or "[]") if title.search(str(w.get("title") or ""))] if code == 0 else []
        except (ValueError, AttributeError):
            matches = []
        if matches and matches[-1].get("id") is not None:
            window = matches[-1]
            wid = int(window["id"])
            arg = str(wid)
            # maximize-column acts on the focused window.
            if wid in _unfilled:
                width, height, before = _unfilled.pop(wid)
                await _run(["niri", "msg", "action", "focus-window", "--id", arg], env)
                await _run(["niri", "msg", "action", "maximize-column"], env)
                await _run(["niri", "msg", "action", "move-window-to-floating", "--id", arg], env)
                await _run(["niri", "msg", "action", "set-window-width", "--id", arg, str(width)], env)
                await _run(["niri", "msg", "action", "set-window-height", "--id", arg, str(height)], env)
                # Back where it was: niri floats it somewhere of its own, so it
                # is moved by the difference to the place it had.
                now = ((await _niri_window(env, wid)) or {}).get("layout", {}).get("tile_pos_in_workspace_view")
                if before and now:
                    dx, dy = round(before[0] - now[0]), round(before[1] - now[1])
                    await _run(["niri", "msg", "action", "move-floating-window", "--id", arg,
                                "-x", f"{dx:+d}", "-y", f"{dy:+d}"], env)
                else:
                    await _run(["niri", "msg", "action", "center-window", "--id", arg], env)
                return {"by": "niri", "maximized": False}
            if not window.get("is_floating"):
                await _run(["niri", "msg", "action", "focus-window", "--id", arg], env)
                await _run(["niri", "msg", "action", "maximize-column"], env)
                return {"by": "niri", "maximized": None}
            layout = window.get("layout") or {}
            size = layout.get("window_size") or [0, 0]
            _unfilled[wid] = (int(size[0]) or 1120, int(size[1]) or 820, layout.get("tile_pos_in_workspace_view"))
            await _run(["niri", "msg", "action", "move-window-to-tiling", "--id", arg], env)
            await _run(["niri", "msg", "action", "focus-window", "--id", arg], env)
            await _run(["niri", "msg", "action", "maximize-column"], env)
            return {"by": "niri", "maximized": True}

    env = hyprland_env()
    if env:
        code, out = await _run(["hyprctl", "-j", "clients"], env)
        try:
            matches = [w for w in json.loads(out or "[]") if title.search(str(w.get("title") or ""))] if code == 0 else []
        except (ValueError, AttributeError):
            matches = []
        if matches and matches[-1].get("address"):
            window = matches[-1]
            await _run(["hyprctl", "dispatch", "focuswindow", f"address:{window['address']}"], env)
            await _run(["hyprctl", "dispatch", "fullscreen", "1"], env)
            return {"by": "hyprland", "maximized": not window.get("fullscreen")}
    return {"by": "", "maximized": None}


async def focus_window(title_part: str, exact: bool = True) -> dict:
    """Bring our window to the user, wherever it is; for "open the window".

    A window left open on another workspace or monitor is easily forgotten,
    and toggling it would close what nobody can see. So when it is not the
    focused window it is focused, which on niri and Hyprland switches to its
    workspace and monitor. Returns which compositor answered ("" for none),
    whether the window was found, and whether it already had the focus, in
    which case the caller closes it instead.
    """
    escaped = re.escape(title_part.strip())
    title = re.compile(f"^{escaped}$" if exact else escaped)

    env = niri_env()
    if env:
        code, out = await _run(["niri", "msg", "-j", "windows"], env)
        try:
            matches = [w for w in json.loads(out or "[]") if title.search(str(w.get("title") or ""))] if code == 0 else []
        except (ValueError, AttributeError):
            matches = []
        if matches:
            window = matches[-1]
            if window.get("is_focused"):
                return {"by": "niri", "found": True, "wasFocused": True}
            await _run(["niri", "msg", "action", "focus-window", "--id", str(window["id"])], env)
            return {"by": "niri", "found": True, "wasFocused": False}
        return {"by": "niri", "found": False, "wasFocused": False}

    env = hyprland_env()
    if env:
        code, out = await _run(["hyprctl", "-j", "clients"], env)
        try:
            matches = [w for w in json.loads(out or "[]") if title.search(str(w.get("title") or ""))] if code == 0 else []
        except (ValueError, AttributeError):
            matches = []
        if matches:
            window = matches[-1]
            # focusHistoryID 0 is the window that has the focus.
            if window.get("focusHistoryID") == 0:
                return {"by": "hyprland", "found": True, "wasFocused": True}
            await _run(["hyprctl", "dispatch", "focuswindow", f"address:{window['address']}"], env)
            return {"by": "hyprland", "found": True, "wasFocused": False}
        return {"by": "hyprland", "found": False, "wasFocused": False}
    return {"by": "", "found": False, "wasFocused": False}


# --------------------------------------------------------------------------
# a native folder picker, for the download dialog's "Choose folder…"
# --------------------------------------------------------------------------
#: (binary, argv builder) in order of preference; whichever is installed.
PICKERS = [
    ("zenity", lambda start, title: ["zenity", "--file-selection", "--directory",
                                     f"--title={title}", f"--filename={start.rstrip('/')}/"]),
    ("kdialog", lambda start, title: ["kdialog", "--title", title, "--getexistingdirectory", start]),
    ("yad", lambda start, title: ["yad", "--file", "--directory", f"--title={title}",
                                  f"--filename={start.rstrip('/')}/"]),
]


def picker_available() -> bool:
    return any(shutil.which(name) for name, _ in PICKERS)


def _display_env() -> dict[str, str]:
    """The session's display, which a systemd user service may not have."""
    env = dict(os.environ)
    if not env.get("WAYLAND_DISPLAY"):
        sockets = sorted(glob.glob(os.path.join(_runtime_dir(), "wayland-[0-9]*")))
        sockets = [s for s in sockets if not s.endswith(".lock")]
        if sockets:
            env["WAYLAND_DISPLAY"] = os.path.basename(sockets[0])
    env.setdefault("XDG_RUNTIME_DIR", _runtime_dir())
    return env


async def open_path(path: str) -> bool:
    """Open a file, or a folder, with the desktop's default app (xdg-open).

    For the manager page's and popup's Open and Show-in-folder buttons: a
    browser page cannot open a local file itself. Fire and forget — xdg-open
    hands off to the app and exits. False when the path is gone or there is no
    xdg-open to ask.
    """
    if not path or not os.path.exists(path) or not shutil.which("xdg-open"):
        return False
    await asyncio.create_subprocess_exec(
        "xdg-open", path, env=_display_env(),
        stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL, start_new_session=True)
    return True


async def pick_folder(start: str, title: str = "Save downloads to") -> str | None:
    """Ask the user for a folder. "" when cancelled, None when no picker exists."""
    for name, argv in PICKERS:
        if not shutil.which(name):
            continue
        proc = await asyncio.create_subprocess_exec(
            *argv(start or os.path.expanduser("~"), title), env=_display_env(),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        try:
            out, _ = await asyncio.wait_for(proc.communicate(), 600)
        except asyncio.TimeoutError:
            proc.kill()
            return ""
        chosen = out.decode("utf-8", "replace").strip().rstrip("|")
        return chosen if proc.returncode == 0 and os.path.isdir(chosen) else ""
    return None
