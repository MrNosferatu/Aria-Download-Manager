"""Shut down or suspend once the downloads are done: a one-off choice.

Set from the quick menu or the header ("When downloads finish: Shut down"),
it waits until nothing is downloading or queued and no finish action
(finishing.py) is still extracting or running, then counts down a minute in
the state, so every front-end can show it with a Cancel. A download that
starts meanwhile puts it back to waiting. When the minute is up the choice
is cleared first, then the command runs: it acts once and never again by
surprise. Paused downloads do not hold it back; seeding torrents neither.

The commands are logind's (systemctl poweroff / suspend), which a user in
the active session may run without root; config can replace them.
"""

from __future__ import annotations

import asyncio
import contextlib
import time
from typing import Callable

ACTIONS = ("shutdown", "suspend")
WORDS = {"shutdown": "Shutting down", "suspend": "Suspending"}


def downloading(snapshot: dict) -> bool:
    """Something is still to finish: running (not just sharing) or queued."""
    for dl in snapshot.get("downloads", []):
        status = dl.get("status")
        if status == "waiting" or (status == "active" and not dl.get("seeder")):
            return True
    return False


class AfterAll:
    def __init__(self, cfg, store, finisher=None,
                 on_event: Callable[..., None] = lambda *a, **k: None):
        self.cfg = cfg
        self.store = store
        self.finisher = finisher
        self.on_event = on_event
        #: "", "shutdown" or "suspend".
        self.action = ""
        #: When the countdown ends (0: not counting down).
        self.deadline = 0.0
        self._timer: asyncio.Task | None = None

    @property
    def countdown(self) -> float:
        return float(self.cfg.get("finish.countdown_seconds", 60))

    def command(self, action: str) -> list[str]:
        default = ["systemctl", "poweroff"] if action == "shutdown" else ["systemctl", "suspend"]
        return list(self.cfg.get(f"finish.{action}_command", default) or default)

    def status(self) -> dict:
        left = max(0.0, self.deadline - time.time()) if self.deadline else None
        return {"action": self.action, "deadline": self.deadline or None,
                "secondsLeft": None if left is None else round(left)}

    def set(self, action: str) -> None:
        action = str(action or "").lower()
        if action and action not in ACTIONS:
            raise ValueError(f"action must be {' or '.join(ACTIONS)}, or empty to cancel")
        before = self.action
        self._stop_countdown()
        self.action = action
        if action:
            self.on_event("info", f"Will {'shut down' if action == 'shutdown' else 'suspend'} when downloads finish")
            self.observe(self.store.snapshot)
        elif before:
            self.on_event("info", "Cancelled: nothing happens when downloads finish")

    def busy(self, snapshot: dict) -> bool:
        return downloading(snapshot) or bool(self.finisher and self.finisher.busy)

    def observe(self, snapshot: dict) -> None:
        if not self.action:
            return
        if self.busy(snapshot):
            if self.deadline:
                self._stop_countdown()
                self.on_event("info", "A download started, so the countdown stopped. Waiting for it to finish.")
            return
        if not self.deadline:
            self.deadline = time.time() + self.countdown
            self.on_event("warn", f"All downloads have finished. {WORDS[self.action]} in {int(self.countdown)} s.")
            self._timer = asyncio.ensure_future(self._count_down())

    def _stop_countdown(self) -> None:
        self.deadline = 0.0
        if self._timer and not self._timer.done():
            self._timer.cancel()
        self._timer = None

    async def _count_down(self) -> None:
        with contextlib.suppress(asyncio.CancelledError):
            await asyncio.sleep(max(0.0, self.deadline - time.time()))
            # The poller may be slow while idle: look again before acting.
            if not self.action or self.busy(self.store.snapshot):
                self.deadline = 0.0
                return
            action, self.action, self.deadline = self.action, "", 0.0
            self.on_event("warn", f"{WORDS[action]} now")
            try:
                proc = await asyncio.create_subprocess_exec(
                    *self.command(action), stdin=asyncio.subprocess.DEVNULL,
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
                _, err = await proc.communicate()
                if proc.returncode:
                    self.on_event("error", f"Couldn’t {'shut down' if action == 'shutdown' else 'suspend'}: "
                                           f"{err.decode('utf-8', 'replace').strip() or f'exit {proc.returncode}'}")
            except OSError as exc:
                self.on_event("error", f"Couldn’t {'shut down' if action == 'shutdown' else 'suspend'}: {exc}")
