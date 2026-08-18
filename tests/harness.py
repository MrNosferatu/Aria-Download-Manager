"""Shared test harness: assertions, counters and small async helpers.

Kept in its own module so that every suite appends to the *same* counters. When
a suite is run directly it becomes ``__main__``, so importing counters from a
sibling suite would otherwise create a second, separate set of them.
"""

from __future__ import annotations

import asyncio
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


def summary() -> int:
    print(f"\n{'=' * 62}")
    print(f"{len(PASSED)} passed, {len(FAILED)} failed")
    for failure in FAILED:
        print(f"  \033[31m✗\033[0m {failure}")
    return 1 if FAILED else 0
