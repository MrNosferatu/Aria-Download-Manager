"""Unix-socket IPC: the manager's only interface.

Loopback HTTP is at the mercy of whatever sits between a client and 127.0.0.1 —
a browser's built-in VPN or proxy can route it away or block it outright. A Unix
socket is a file: nothing proxies it. It is also private to this user (mode
0600), which a TCP port never was, and no website can reach it.

Protocol: newline-delimited JSON, one object per line, both directions.

    -> {"id": 1, "method": "GET",  "path": "/api/state"}
    <- {"id": 1, "status": 200, "body": {...}}

    -> {"id": 2, "method": "POST", "path": "/api/downloads", "body": {"uris": [...]}}
    <- {"id": 2, "status": 200, "body": {"ok": true, "gids": [...]}}

    -> {"id": 3, "method": "SUBSCRIBE"}
    <- {"id": 3, "status": 200, "body": {"ok": true}}
    <- {"event": "state",   "data": {...}}       # then live frames
    <- {"event": "backlog", "data": [...]}
    -> {"id": 4, "method": "UNSUBSCRIBE"}

Routes, validation and error statuses come from the FastAPI app in api.py, run
in-process: each request is handed straight to it, and no HTTP server exists.
Requests on one connection run concurrently: a slow media probe does not hold up
the state poll queued behind it.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import socket
from pathlib import Path
from typing import Any
from urllib.parse import unquote

from .native_host import default_socket_path

#: A .torrent sent as base64 can be a few MiB; asyncio's 64 KiB default line
#: limit would cut the connection on it.
LINE_LIMIT = 64 * 1024 * 1024


def socket_path_for(cfg) -> str:
    configured = str(cfg.get("server.socket") or "").strip()
    return os.path.expanduser(configured) if configured else default_socket_path()


async def call_app(app, method: str, path: str, body: Any = None) -> tuple[int, Any]:
    """Run one request through the ASGI app and return (status, decoded body)."""
    raw_path, _, query = path.partition("?")
    payload = b"" if body is None else json.dumps(body).encode("utf-8")
    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": method.upper(),
        "scheme": "http",
        "path": unquote(raw_path),
        "raw_path": raw_path.encode("utf-8"),
        "query_string": query.encode("utf-8"),
        "root_path": "",
        "headers": [
            (b"host", b"ipc"),
            (b"content-type", b"application/json"),
            (b"content-length", str(len(payload)).encode()),
        ],
        "client": ("ipc", 0),
        "server": ("ipc", 0),
    }
    sent_body = False
    finished = asyncio.Event()

    async def receive():
        nonlocal sent_body
        if not sent_body:
            sent_body = True
            return {"type": "http.request", "body": payload, "more_body": False}
        # Only reached by something waiting for a disconnect; there is none
        # until the response is complete.
        await finished.wait()
        return {"type": "http.disconnect"}

    status = 500
    chunks: list[bytes] = []

    async def send(message):
        nonlocal status
        if message["type"] == "http.response.start":
            status = message["status"]
        elif message["type"] == "http.response.body":
            chunks.append(message.get("body", b""))
            if not message.get("more_body"):
                finished.set()

    try:
        await app(scope, receive, send)
    except Exception as exc:  # Starlette re-raises after sending its 500
        if not finished.is_set():
            return 500, {"ok": False, "error": f"internal error: {exc}"}
    finally:
        finished.set()

    raw = b"".join(chunks)
    if not raw:
        return status, None
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, raw.decode("utf-8", "replace")


class SocketInUse(RuntimeError):
    """Another manager is already answering on the socket."""


class IPCServer:
    def __init__(self, app, store, path: str):
        self.app = app
        self.store = store
        self.path = path
        self._server: asyncio.AbstractServer | None = None
        self._connections: set[asyncio.Task] = set()

    # ---- lifecycle -------------------------------------------------------
    async def start(self) -> None:
        target = Path(self.path)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() or target.is_symlink():
            if await self._is_live(target):
                raise SocketInUse(
                    f"another Aria Download Manager is already listening on {target}")
            target.unlink()  # left behind by a manager that did not exit cleanly
        # Created 0600 from the start rather than chmod-ed after: there is no
        # window in which another user could connect.
        old_umask = os.umask(0o177)
        try:
            self._server = await asyncio.start_unix_server(
                self._serve, path=str(target), limit=LINE_LIMIT)
        finally:
            os.umask(old_umask)

    @staticmethod
    async def _is_live(target: Path) -> bool:
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        probe.setblocking(False)
        try:
            await asyncio.get_running_loop().sock_connect(probe, str(target))
            return True
        except OSError:
            return False
        finally:
            probe.close()

    async def stop(self) -> None:
        if self._server is None:
            return
        self._server.close()
        for task in list(self._connections):
            task.cancel()
        for task in list(self._connections):
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        with contextlib.suppress(Exception):
            await self._server.wait_closed()
        self._server = None
        with contextlib.suppress(OSError):
            os.unlink(self.path)

    # ---- one client ------------------------------------------------------
    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        task = asyncio.current_task()
        self._connections.add(task)
        write_lock = asyncio.Lock()
        requests: set[asyncio.Task] = set()
        subscription: asyncio.Task | None = None

        async def write(message: dict) -> None:
            async with write_lock:
                writer.write(json.dumps(message).encode("utf-8") + b"\n")
                await writer.drain()

        async def answer(request: dict) -> None:
            request_id = request.get("id")
            try:
                status, body = await call_app(
                    self.app,
                    str(request.get("method") or "GET"),
                    str(request.get("path") or "/"),
                    request.get("body"),
                )
            except Exception as exc:
                status, body = 500, {"ok": False, "error": str(exc)}
            with contextlib.suppress(ConnectionError, RuntimeError):
                await write({"id": request_id, "status": status, "body": body})

        async def stream() -> None:
            queue = self.store.subscribe()
            try:
                await write({"event": "state", "data": self.store.snapshot})
                await write({"event": "backlog", "data": self.store.event_list(60)})
                while True:
                    message = await queue.get()
                    await write({"event": message.get("type", "message"),
                                 "data": message.get("data")})
                    if message.get("type") == "shutdown":
                        # Ends the connection so the client reconnects to the
                        # next manager instead of holding this one open.
                        writer.close()
                        return
            except (ConnectionError, RuntimeError):
                pass
            finally:
                self.store.unsubscribe(queue)

        try:
            while True:
                try:
                    line = await reader.readline()
                except (ValueError, asyncio.LimitOverrunError):
                    await write({"id": None, "status": 413,
                                 "body": {"ok": False, "error": "request too large"}})
                    break
                if not line:
                    break
                try:
                    request = json.loads(line)
                    if not isinstance(request, dict):
                        raise ValueError("not an object")
                except ValueError as exc:
                    await write({"id": None, "status": 400,
                                 "body": {"ok": False, "error": f"bad request line: {exc}"}})
                    continue

                method = str(request.get("method") or "GET").upper()
                if method == "SUBSCRIBE":
                    if subscription is None or subscription.done():
                        subscription = asyncio.create_task(stream())
                    await write({"id": request.get("id"), "status": 200, "body": {"ok": True}})
                    continue
                if method == "UNSUBSCRIBE":
                    if subscription is not None:
                        subscription.cancel()
                        subscription = None
                    await write({"id": request.get("id"), "status": 200, "body": {"ok": True}})
                    continue

                job = asyncio.create_task(answer(request))
                requests.add(job)
                job.add_done_callback(requests.discard)
        except (ConnectionError, asyncio.CancelledError):
            pass
        finally:
            if subscription is not None:
                subscription.cancel()
            for job in list(requests):
                job.cancel()
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()
            self._connections.discard(task)
