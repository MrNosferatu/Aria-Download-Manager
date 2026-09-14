"""Shared test harness: assertions, counters and small async helpers.

Kept in its own module so that every suite appends to the *same* counters. When
a suite is run directly it becomes ``__main__``, so importing counters from a
sibling suite would otherwise create a second, separate set of them.
"""

from __future__ import annotations

import asyncio
import contextlib
import itertools
import json
import socket
import time

PASSED: list[str] = []
FAILED: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        PASSED.append(name)
        print(f"  \033[32mPASS\033[0m {name}")
    else:
        FAILED.append(f"{name}{f' — {detail}' if detail else ''}")
        print(f"  \033[31mFAIL\033[0m {name}" + (f" — {detail}" if detail else ""))


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


async def wait_for(predicate, timeout: float, interval: float = 0.25) -> bool:
    """Poll `predicate` (sync or async) until it is truthy or time runs out."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if asyncio.iscoroutine(result):
            result = await result
        if result:
            return True
        await asyncio.sleep(interval)
    return False


class IPCResponse:
    def __init__(self, status: int, body):
        self.status = status
        self._body = body

    async def json(self):
        return self._body

    async def text(self) -> str:
        return self._body if isinstance(self._body, str) else json.dumps(self._body)


class IPCSession:
    """The manager's socket, with the call shape the suites were written against.

    `async with session.get(path) as res:` then `res.status` / `await res.json()`.
    Each call opens its own connection, so a manager restart between calls is
    just a refused connection rather than a dead session.
    """

    def __init__(self, path: str):
        self.path = str(path)
        self._ids = itertools.count(1)

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def call(self, method: str, path: str, body=None, timeout: float = 30.0) -> IPCResponse:
        reader, writer = await asyncio.wait_for(
            asyncio.open_unix_connection(self.path, limit=64 * 1024 * 1024), timeout)
        try:
            request_id = next(self._ids)
            message = {"id": request_id, "method": method, "path": path}
            if body is not None:
                message["body"] = body
            writer.write((json.dumps(message) + "\n").encode())
            await writer.drain()
            while True:
                line = await asyncio.wait_for(reader.readline(), timeout)
                if not line:
                    raise ConnectionError("manager closed the connection")
                reply = json.loads(line)
                if reply.get("id") == request_id:
                    return IPCResponse(reply["status"], reply.get("body"))
        finally:
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()

    @contextlib.asynccontextmanager
    async def _request(self, method, path, body=None, timeout=30.0):
        yield await self.call(method, path, body, timeout)

    def get(self, path, timeout=30.0):
        return self._request("GET", path, timeout=timeout)

    def post(self, path, json=None, timeout=30.0):
        return self._request("POST", path, json, timeout)

    def delete(self, path, timeout=30.0):
        return self._request("DELETE", path, timeout=timeout)


class ManagerRunner:
    """Runs an app the way `python -m aria2c_manager` does, inside a test."""

    def __init__(self, app):
        from aria2c_manager.api import run

        self.app = app
        self.started = False
        self._stop = asyncio.Event()
        self._run = run

    async def serve(self) -> None:
        await self._run(self.app, self._stop, started=lambda: setattr(self, "started", True))

    def stop(self) -> None:
        self._stop.set()


def summary() -> int:
    print(f"\n{'=' * 62}")
    print(f"{len(PASSED)} passed, {len(FAILED)} failed")
    for failure in FAILED:
        print(f"  \033[31mFAIL\033[0m {failure}")
    return 1 if FAILED else 0
