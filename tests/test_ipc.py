"""IPC checks: the Unix socket, and the native-messaging host in front of it.

    python3 tests/test_ipc.py

Runs the manager against tests/fake_aria2.py like test_manager.py does, then
talks to it only through the socket — and through the real native host process,
framed exactly the way a browser frames it.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
# The state dir (RPC secret, history) is fixed when the package is imported, so it
# has to point somewhere disposable before that, not at the real one.
os.environ["XDG_DATA_HOME"] = tempfile.mkdtemp(prefix="aria-download-manager-test-data-")

from aria_download_manager import native_host  # noqa: E402
from aria_download_manager.api import create_app  # noqa: E402
from aria_download_manager.config import Config  # noqa: E402
from aria_download_manager.ipc import SocketInUse  # noqa: E402
from aria_download_manager.config import DEFAULTS  # noqa: E402

# These suites drive aria2c (real or fake). Torrents would otherwise go to a
# qbittorrent-nox if one happens to be installed; tests/test_qbittorrent.py
# covers that engine.
DEFAULTS["torrent"]["engine"] = "aria2"
from tests.fake_aria2 import serve  # noqa: E402
from tests.harness import ManagerRunner, check, free_port, summary, wait_for  # noqa: E402


class Client:
    """Minimal line-protocol client, the shape the DMS widget uses."""

    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.next_id = 0

    async def send(self, method, path="", body=None):
        self.next_id += 1
        message = {"id": self.next_id, "method": method, "path": path}
        if body is not None:
            message["body"] = body
        self.writer.write((json.dumps(message) + "\n").encode())
        await self.writer.drain()
        return self.next_id

    async def read(self, timeout=5.0):
        line = await asyncio.wait_for(self.reader.readline(), timeout)
        return json.loads(line) if line else None

    async def call(self, method, path="", body=None):
        request_id = await self.send(method, path, body)
        while True:
            message = await self.read()
            if message is None or message.get("id") == request_id:
                return message


def tcp_listen_ports() -> set[int]:
    """Ports this process is listening on over TCP, read from /proc."""
    inodes = set()
    for fd in Path("/proc/self/fd").iterdir():
        with contextlib.suppress(OSError):
            target = os.readlink(fd)
            if target.startswith("socket:["):
                inodes.add(target[8:-1])
    ports = set()
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        with contextlib.suppress(OSError):
            for line in Path(table).read_text().splitlines()[1:]:
                fields = line.split()
                # state 0A is LISTEN; field 9 is the socket inode
                if fields[3] == "0A" and fields[9] in inodes:
                    ports.add(int(fields[1].rsplit(":", 1)[1], 16))
    return ports


def frame(message: dict) -> bytes:
    data = json.dumps(message).encode()
    return struct.pack("=I", len(data)) + data


_unread: dict[int, bytes] = {}


def read_frames(proc, count, timeout=10.0) -> list[dict]:
    """Read `count` whole replies from the host, reassembling split ones.

    Reads the pipe's fd directly: select() on a buffered file object misses
    frames the buffer has already swallowed, and the test then times out on data
    that has in fact arrived.
    """
    import select
    import time

    fd = proc.stdout.fileno()
    data = _unread.pop(fd, b"")
    deadline = time.monotonic() + timeout

    def take(n: int) -> bytes | None:
        nonlocal data
        while len(data) < n:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([fd], [], [], left)[0]:
                return None
            chunk = os.read(fd, 65536)
            if not chunk:
                return None
            data += chunk
        piece, data = data[:n], data[n:]
        return piece

    out, buffer = [], ""
    while len(out) < count:
        header = take(4)
        if header is None:
            break
        (length,) = struct.unpack("=I", header)
        body = take(length)
        if body is None:
            break
        message = json.loads(body)
        if "part" in message:
            buffer += message["part"]
            if message["more"]:
                continue
            message, buffer = json.loads(buffer), ""
        out.append(message)
    _unread[fd] = data
    return out


async def test_ipc(tmp_dir: Path) -> None:
    tmp_dir.mkdir(parents=True, exist_ok=True)
    rpc_port = free_port()
    httpd, _fake = serve(rpc_port, secret="test-secret")
    sock_path = tmp_dir / "run" / "manager.sock"

    config_path = tmp_dir / "config.yaml"
    config_path.write_text(yaml.safe_dump({
        "server": {"socket": str(sock_path)},
        "poll_interval": 0.5,
        "aria2": {"managed": False,
                  "rpc": {"host": "127.0.0.1", "port": rpc_port, "secret": "test-secret"}},
        "history": {"enabled": False, "file": str(tmp_dir / "history.json")},
    }))
    # A stale socket file from a crashed run must not block startup.
    sock_path.parent.mkdir(parents=True)
    sock_path.write_text("stale")

    app = create_app(Config(config_path))
    server = ManagerRunner(app)
    task = asyncio.create_task(server.serve())
    try:
        print("\nipc: socket")
        up = await wait_for(lambda: server.started and sock_path.is_socket(), 15)
        check("socket is created, replacing a stale file", up)
        if not up:
            return
        mode = stat.S_IMODE(os.stat(sock_path).st_mode)
        check("socket is private to this user (0600)", mode == 0o600, oct(mode))

        listening = tcp_listen_ports() - {rpc_port}  # the fake aria2 lives in this process
        check("nothing listens on the network (no TCP port)", not listening, str(listening))

        second = create_app(Config(config_path)).state.ipc
        try:
            await second.start()
            check("a second manager refuses a live socket", False)
        except SocketInUse:
            check("a second manager refuses a live socket", True)

        client = Client(*await asyncio.open_unix_connection(str(sock_path)))
        ping = await client.call("GET", "/api/intake/ping")
        check("GET routes through the API", ping["status"] == 200 and ping["body"]["ok"], str(ping))
        check("ping reports the socket path", ping["body"].get("socket") == str(sock_path))

        await wait_for(lambda: bool(app.state.store.snapshot["downloads"]), 10)
        state = await client.call("GET", "/api/state")
        check("state comes back over IPC", len(state["body"]["downloads"]) >= 3,
              str(state)[:200])

        added = await client.call("POST", "/api/downloads",
                                  {"uris": ["https://example.test/ipc.bin"]})
        check("POST with a JSON body works", added["status"] == 200 and added["body"]["gids"],
              str(added))

        options = await client.call("GET", "/api/history?limit=5")
        check("query strings reach the endpoint", options["status"] == 200, str(options)[:200])

        missing = await client.call("POST", "/api/rules/nope/toggle")
        check("error statuses keep their code and detail",
              missing["status"] == 404 and "no rule named" in json.dumps(missing["body"]),
              str(missing))

        bad = await client.call("POST", "/api/downloads", {"uris": []})
        check("validation errors come back as 400", bad["status"] == 400, str(bad))

        print("\nipc: event stream")
        sub = await client.call("SUBSCRIBE")
        check("subscribe is acknowledged", sub["status"] == 200)
        first = await client.read()
        second_frame = await client.read()
        check("stream opens with a state frame", first.get("event") == "state", str(first)[:120])
        check("then the event backlog", second_frame.get("event") == "backlog")
        await client.send("POST", "/api/global/pause-all")
        seen_event = seen_reply = False
        for _ in range(40):
            message = await client.read()
            seen_event |= message.get("event") == "state"
            seen_reply |= message.get("id") == client.next_id
            if seen_event and seen_reply:
                break
        check("replies and live frames share one connection", seen_event and seen_reply)
        await client.call("UNSUBSCRIBE")
        client.writer.close()

        # Two requests on one connection: the second must not wait for the first.
        concurrent = Client(*await asyncio.open_unix_connection(str(sock_path)))
        slow = await concurrent.send("POST", "/api/media/probe",
                                     {"url": "http://10.255.255.1/never.m3u8"})
        fast = await concurrent.send("GET", "/api/intake/ping")
        reply = await concurrent.read(timeout=5)
        check("a slow request does not block a fast one", reply and reply.get("id") == fast,
              str(reply)[:120])
        concurrent.writer.close()
        del slow

        print("\nipc: native-messaging host")
        env = {**os.environ, native_host.SOCKET_ENV: str(sock_path)}
        proc = subprocess.Popen([sys.executable, str(ROOT / "aria_download_manager" / "native_host.py")],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        proc.stdin.write(frame({"id": "a", "method": "GET", "path": "/api/intake/ping"}))
        proc.stdin.write(frame({"id": "b", "method": "POST", "path": "/api/intake/add",
                                "body": {"url": "https://example.test/from-browser.iso",
                                         "cookie": "s=1"}}))
        proc.stdin.flush()
        replies = await asyncio.to_thread(read_frames, proc, 2)
        by_id = {r.get("id"): r for r in replies}
        check("host relays a ping", by_id.get("a", {}).get("status") == 200, str(replies)[:200])
        check("host relays an intake add",
              by_id.get("b", {}).get("body", {}).get("count") == 1, str(replies)[:200])

        # Oversized reply: must arrive split and reassemble to the original.
        big_line = json.dumps({"id": "big", "status": 200, "body": {"blob": "x" * 1_500_000}})
        buffer = __import__("io").BytesIO()
        native_host.Relay("unused", stdin=None, stdout=buffer).write_line(big_line)
        raw, frames, pos = buffer.getvalue(), [], 0
        while pos < len(raw):
            (length,) = struct.unpack("=I", raw[pos:pos + 4])
            frames.append(json.loads(raw[pos + 4:pos + 4 + length]))
            pos += 4 + length
        check("a reply over 1 MiB is split into frames under 1 MiB",
              len(frames) > 1 and all(len(json.dumps(f)) < 1024 * 1024 for f in frames))
        check("and reassembles exactly", "".join(f["part"] for f in frames) == big_line)

        proc.stdin.close()
        check("host exits when the browser closes the port", proc.wait(timeout=5) == 0)

        # The manager going away must reach the extension even with nothing
        # pending: a live event stream has no request to fail.
        brief_path = tmp_dir / "brief.sock"
        brief = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        brief.bind(str(brief_path))
        brief.listen(1)

        def answer_once_then_close():
            conn, _ = brief.accept()
            with conn:
                request = json.loads(conn.makefile().readline())
                conn.sendall((json.dumps({"id": request["id"], "status": 200,
                                          "body": {"ok": True}}) + "\n").encode())
            brief.close()

        threading.Thread(target=answer_once_then_close, daemon=True).start()
        short = subprocess.Popen(
            [sys.executable, str(ROOT / "aria_download_manager" / "native_host.py")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            env={**os.environ, native_host.SOCKET_ENV: str(brief_path)})
        short.stdin.write(frame({"id": 1, "method": "SUBSCRIBE"}))
        short.stdin.flush()
        got = await asyncio.to_thread(read_frames, short, 2)
        check("host reports the manager closing the socket",
              len(got) == 2 and got[0].get("id") == 1 and got[1].get("event") == "disconnected",
              str(got))
        short.stdin.close()
        short.wait(timeout=5)

        dead = subprocess.Popen(
            [sys.executable, str(ROOT / "aria_download_manager" / "native_host.py")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            env={**os.environ, native_host.SOCKET_ENV: str(tmp_dir / "nothing.sock")})
        dead.stdin.write(frame({"id": 7, "method": "GET", "path": "/api/state"}))
        dead.stdin.flush()
        [offline] = (await asyncio.to_thread(read_frames, dead, 1)) or [{}]
        check("no manager: the host answers with a clear error",
              offline.get("status") == 503 and "not running" in offline["body"]["error"],
              str(offline))
        dead.stdin.close()
        dead.wait(timeout=5)
    finally:
        server.stop()
        await asyncio.wait_for(task, 15)
        httpd.shutdown()
    check("socket file is removed on shutdown", not sock_path.exists())


def test_install(tmp_dir: Path) -> None:
    print("\nipc: installing the host manifest")
    home = tmp_dir / "home"
    ext_dir = tmp_dir / "extension"
    ext_dir.mkdir(parents=True)
    profile = home / ".config" / "chromium" / "Default"
    profile.mkdir(parents=True)
    (profile / "Secure Preferences").write_text(json.dumps({"extensions": {"settings": {
        "abcdefghijklmnopabcdefghijklmnop": {"path": str(ext_dir)},
        "ponmlkjihgfedcbaponmlkjihgfedcba": {"path": "/somewhere/else"},
    }}}))
    old_home = os.environ.get("HOME")
    os.environ["HOME"] = str(home)
    try:
        report = native_host.install("/run/test.sock", ext_dir, [], home / "state")
    finally:
        if old_home is not None:
            os.environ["HOME"] = old_home

    firefox = json.loads((home / ".mozilla/native-messaging-hosts/aria_download_manager.json").read_text())
    check("firefox manifest names the gecko id",
          firefox["allowed_extensions"] == ["aria-download-manager@fhadwanur"], str(firefox))
    chromium = json.loads(
        (home / ".config/chromium/NativeMessagingHosts/aria_download_manager.json").read_text())
    check("chromium manifest finds the unpacked extension's id, and only that one",
          chromium["allowed_origins"] == ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"],
          str(chromium))
    launcher = Path(firefox["path"])
    check("launcher is executable and carries the socket path",
          os.access(launcher, os.X_OK) and "/run/test.sock" in launcher.read_text())
    check("browsers with no profile are left alone",
          not (home / ".config/google-chrome").exists(), "\n".join(report))


def main() -> int:
    tmp_dir = Path(tempfile.mkdtemp(prefix="aria-download-manager-ipc-test-"))
    try:
        test_install(tmp_dir / "install")
        asyncio.run(test_ipc(tmp_dir / "e2e"))
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
    return summary()


if __name__ == "__main__":
    raise SystemExit(main())
