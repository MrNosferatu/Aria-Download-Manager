#!/usr/bin/env python3
"""Native-messaging host: relays the browser extension to the manager's socket.

A browser extension cannot open a Unix socket, and its fetch() to 127.0.0.1 goes
through whatever the browser routes traffic through — an in-browser VPN or proxy
can swallow loopback requests entirely. Native messaging is the one channel an
extension has that is not network at all: the browser spawns this process and
talks to it over stdin/stdout. This process then speaks the manager's IPC
protocol (see ipc.py) over the Unix socket.

Deliberately standard-library only, and never imports the rest of the package:
the browser starts it on demand and it should be up in milliseconds, not wait
for FastAPI to import.

    python3 aria2c_manager/native_host.py      # what the browser runs
"""

from __future__ import annotations

import json
import os
import socket
import struct
import sys
import tempfile
import threading
from pathlib import Path

HOST_NAME = "com.aria2c.manager"
FIREFOX_EXTENSION_ID = "aria2c-manager@fhadwanur"
SOCKET_ENV = "ARIA2C_MANAGER_SOCKET"
SOCKET_NAME = "aria2c-manager.sock"

#: Chrome refuses a message from the host larger than 1 MiB. A state snapshot
#: with a long download list can pass that, so big replies go out in parts.
MAX_FRAME = 1024 * 1024
PART_CHARS = 128 * 1024  # escaping can double it; non-ASCII can quadruple


def default_socket_path() -> str:
    """Where the manager listens unless server.socket says otherwise.

    $XDG_RUNTIME_DIR is per-user, mode 0700 and cleared at logout — the right
    home for a socket with no authentication of its own.
    """
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        candidate = f"/run/user/{os.getuid()}"
        runtime = candidate if os.path.isdir(candidate) else ""
    if runtime:
        return os.path.join(runtime, SOCKET_NAME)
    return os.path.join(tempfile.gettempdir(), f"aria2c-manager-{os.getuid()}.sock")


# --------------------------------------------------------------------------
# the relay
# --------------------------------------------------------------------------
class Relay:
    def __init__(self, socket_path: str, stdin=None, stdout=None):
        self.socket_path = socket_path
        self.stdin = stdin or sys.stdin.buffer
        self.stdout = stdout or sys.stdout.buffer
        self._out_lock = threading.Lock()
        self._sock_lock = threading.Lock()
        self._sock: socket.socket | None = None
        #: Request ids sent and not yet answered, so a manager that goes away
        #: mid-request fails them at once instead of leaving the extension to
        #: sit out its timeout.
        self._pending: set = set()

    # ---- browser side ---------------------------------------------------
    def read_frame(self) -> dict | None:
        header = self.stdin.read(4)
        if len(header) < 4:
            return None
        (length,) = struct.unpack("=I", header)
        data = self.stdin.read(length)
        if len(data) < length:
            return None
        return json.loads(data)

    def write_line(self, line: str) -> None:
        """Send one manager reply to the browser, in parts if it is too big."""
        encoded = line.encode("utf-8")
        with self._out_lock:
            if len(encoded) + 4 <= MAX_FRAME:
                self._write_raw(encoded)
                return
            for start in range(0, len(line), PART_CHARS):
                piece = line[start:start + PART_CHARS]
                more = start + PART_CHARS < len(line)
                self._write_raw(json.dumps({"part": piece, "more": more}).encode("utf-8"))

    def write_message(self, message: dict) -> None:
        self.write_line(json.dumps(message))

    def _write_raw(self, payload: bytes) -> None:
        self.stdout.write(struct.pack("=I", len(payload)))
        self.stdout.write(payload)
        self.stdout.flush()

    # ---- manager side ---------------------------------------------------
    def _connect(self) -> socket.socket:
        with self._sock_lock:
            if self._sock is not None:
                return self._sock
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(self.socket_path)
            except OSError:
                sock.close()
                raise
            self._sock = sock
            threading.Thread(target=self._pump, args=(sock,), daemon=True).start()
            return sock

    def _pump(self, sock: socket.socket) -> None:
        reader = sock.makefile("r", encoding="utf-8", newline="\n")
        try:
            for line in reader:
                line = line.rstrip("\n")
                if not line:
                    continue
                try:
                    reply_id = json.loads(line).get("id")
                except (ValueError, AttributeError):
                    continue
                self._pending.discard(reply_id)
                self.write_line(line)
        except OSError:
            pass
        finally:
            with self._sock_lock:
                if self._sock is sock:
                    self._sock = None
            sock.close()
            for request_id in list(self._pending):
                self._pending.discard(request_id)
                self._fail(request_id, "aria2c-manager closed the connection")
            # A live event stream ends with the connection, and nothing else would
            # tell the extension: it has to ask again once a manager is back.
            try:
                self.write_message({"event": "disconnected", "data": None})
            except OSError:
                pass  # the browser has already gone

    def _fail(self, request_id, message: str) -> None:
        self.write_message({"id": request_id, "status": 503,
                            "body": {"ok": False, "error": message}})

    def handle(self, message: dict) -> None:
        request_id = message.get("id")
        try:
            sock = self._connect()
        except FileNotFoundError:
            self._fail(request_id, "aria2c-manager is not running "
                                   f"(no socket at {self.socket_path})")
            return
        except OSError as exc:
            self._fail(request_id, f"cannot reach aria2c-manager at {self.socket_path}: "
                                   f"{exc.strerror or exc}")
            return
        self._pending.add(request_id)
        try:
            sock.sendall((json.dumps(message) + "\n").encode("utf-8"))
        except OSError as exc:
            self._pending.discard(request_id)
            self._fail(request_id, f"lost aria2c-manager: {exc.strerror or exc}")

    def run(self) -> int:
        while True:
            try:
                message = self.read_frame()
            except ValueError:
                continue  # not JSON — nothing sensible to answer
            if message is None:
                return 0  # the browser closed the port
            if isinstance(message, dict):
                self.handle(message)


# --------------------------------------------------------------------------
# installing the host manifest
# --------------------------------------------------------------------------
FIREFOX_DIRS = [
    "~/.mozilla/native-messaging-hosts",
    "~/.librewolf/native-messaging-hosts",
]
#: Chromium-family browsers, each only when its profile directory exists.
CHROMIUM_DIRS = [
    "~/.config/google-chrome",
    "~/.config/google-chrome-beta",
    "~/.config/chromium",
    "~/.config/BraveSoftware/Brave-Browser",
    "~/.config/vivaldi",
    "~/.config/microsoft-edge",
]


def find_chromium_extension_ids(profile_root: Path, extension_dir: Path) -> set[str]:
    """Ids a Chromium browser gave this extension when it was loaded unpacked.

    An unpacked extension's id is derived from its path, so it differs per
    machine; reading it back from the profile saves asking the user for it.
    """
    found: set[str] = set()
    target = str(extension_dir.resolve())
    for prefs in profile_root.glob("*/*Preferences"):
        try:
            data = json.loads(prefs.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        settings = (data.get("extensions") or {}).get("settings") or {}
        for ext_id, info in settings.items():
            path = (info or {}).get("path") or ""
            if path and os.path.realpath(path) == target:
                found.add(ext_id)
    return found


def install(socket_path: str, extension_dir: Path, chrome_ids: list[str],
            state_dir: Path, python: str | None = None) -> list[str]:
    """Write the launcher and every browser's host manifest. Returns a report."""
    report: list[str] = []
    state_dir.mkdir(parents=True, exist_ok=True)
    launcher = state_dir / "aria2c-native-host"
    # A wrapper rather than pointing the manifest at this file: the manifest has
    # no way to pass arguments, and the socket path may not be the default.
    launcher.write_text(
        "#!/bin/sh\n"
        "# Generated by `aria2c-manager --install-native-host`. Re-run that after\n"
        "# moving the checkout or changing server.socket.\n"
        f"{SOCKET_ENV}='{socket_path}' exec '{python or sys.executable}' "
        f"'{Path(__file__).resolve()}' \"$@\"\n",
        encoding="utf-8",
    )
    launcher.chmod(0o755)
    report.append(f"launcher   {launcher}")

    base = {
        "name": HOST_NAME,
        "description": "aria2c-manager IPC bridge",
        "path": str(launcher),
        "type": "stdio",
    }
    for directory in FIREFOX_DIRS:
        target = Path(directory).expanduser()
        # ~/.mozilla is written even before first run; the others only if present.
        if not target.parent.is_dir() and not directory.startswith("~/.mozilla"):
            continue
        target.mkdir(parents=True, exist_ok=True)
        manifest = {**base, "allowed_extensions": [FIREFOX_EXTENSION_ID]}
        (target / f"{HOST_NAME}.json").write_text(json.dumps(manifest, indent=2) + "\n")
        report.append(f"firefox    {target / (HOST_NAME + '.json')}")

    for directory in CHROMIUM_DIRS:
        root = Path(directory).expanduser()
        if not root.is_dir():
            continue
        ids = sorted(set(chrome_ids) | find_chromium_extension_ids(root, extension_dir))
        target = root / "NativeMessagingHosts" / f"{HOST_NAME}.json"
        if not ids:
            report.append(f"skipped    {root.name}: extension not loaded there "
                          "(load it unpacked, or pass --chrome-extension-id)")
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        manifest = {**base, "allowed_origins": [f"chrome-extension://{i}/" for i in ids]}
        target.write_text(json.dumps(manifest, indent=2) + "\n")
        report.append(f"chromium   {target} ({', '.join(ids)})")
    return report


def main() -> int:
    socket_path = os.environ.get(SOCKET_ENV) or default_socket_path()
    return Relay(socket_path).run()


if __name__ == "__main__":
    raise SystemExit(main())
