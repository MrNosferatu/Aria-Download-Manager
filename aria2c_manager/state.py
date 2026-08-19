"""Snapshot polling, normalisation and fan-out to SSE subscribers."""

from __future__ import annotations

import asyncio
import itertools
import os
import time
from collections import deque
from typing import Any

from .rpc import STATUS_KEYS, Aria2RPC

ACTIVE_STATUSES = ("active",)
WAITING_STATUSES = ("waiting", "paused")

#: Samples kept per download, and the shortest span worth dividing by. At the
#: default 1s poll interval this measures speed over roughly three seconds.
SPEED_SAMPLES = 4
MIN_SPEED_WINDOW = 1.5


def _int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def derive_name(item: dict) -> str:
    bt = item.get("bittorrent") or {}
    info = bt.get("info") or {}
    if info.get("name"):
        return str(info["name"])
    files = item.get("files") or []
    if files:
        path = files[0].get("path") or ""
        if path:
            return os.path.basename(path.rstrip("/")) or path
        uris = files[0].get("uris") or []
        if uris and uris[0].get("uri"):
            return os.path.basename(uris[0]["uri"].split("?")[0]) or uris[0]["uri"]
    if item.get("infoHash"):
        return f"[metadata] {item['infoHash'][:16]}"
    return item.get("gid", "?")


def normalize(item: dict) -> dict:
    total = _int(item.get("totalLength"))
    done = _int(item.get("completedLength"))
    speed = _int(item.get("downloadSpeed"))
    up_speed = _int(item.get("uploadSpeed"))
    files = item.get("files") or []
    eta = None
    if speed > 0 and total > done:
        eta = round((total - done) / speed)
    return {
        "gid": item.get("gid", ""),
        "status": item.get("status", "unknown"),
        "name": derive_name(item),
        "total": total,
        "completed": done,
        "uploaded": _int(item.get("uploadLength")),
        "progress": round(done / total * 100, 2) if total else 0.0,
        "downloadSpeed": speed,
        "uploadSpeed": up_speed,
        "connections": _int(item.get("connections")),
        "numSeeders": _int(item.get("numSeeders")),
        "seeder": item.get("seeder") == "true",
        "dir": item.get("dir", ""),
        "eta": eta,
        "numFiles": len(files),
        "numPieces": _int(item.get("numPieces")),
        "pieceLength": _int(item.get("pieceLength")),
        "isTorrent": bool(item.get("bittorrent")),
        "infoHash": item.get("infoHash", ""),
        "errorCode": item.get("errorCode"),
        "errorMessage": item.get("errorMessage"),
        "following": item.get("following"),
        "followedBy": item.get("followedBy") or [],
        "path": (files[0].get("path") if files else "") or "",
        "firstUri": next(
            (
                u.get("uri")
                for f in files
                for u in (f.get("uris") or [])
                if u.get("uri")
            ),
            "",
        ),
    }


class Store:
    """Latest snapshot + rolling event log + SSE subscriber queues."""

    def __init__(self, max_events: int = 500):
        self.snapshot: dict[str, Any] = {
            "ts": 0.0,
            "downloads": [],
            "global": {},
            "counts": {},
            "aria2": {},
            "rules": {},
        }
        self.events: deque[dict] = deque(maxlen=max_events)
        self._subscribers: set[asyncio.Queue] = set()
        self._ids = itertools.count(1)

    # ---- pub/sub ---------------------------------------------------------
    def subscribe(self) -> asyncio.Queue:
        queue: asyncio.Queue = asyncio.Queue(maxsize=32)
        self._subscribers.add(queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue) -> None:
        self._subscribers.discard(queue)

    @property
    def has_subscribers(self) -> bool:
        """Is any UI actually watching the stream right now?"""
        return bool(self._subscribers)

    def publish(self, message: dict) -> None:
        for queue in list(self._subscribers):
            if queue.full():  # slow client: drop the oldest frame
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            try:
                queue.put_nowait(message)
            except asyncio.QueueFull:
                pass

    # ---- events ----------------------------------------------------------
    def add_event(self, level: str, message: str, **extra: Any) -> dict:
        event = {
            "id": next(self._ids),
            "ts": time.time(),
            "level": level,
            "message": message,
            **extra,
        }
        self.events.appendleft(event)
        self.publish({"type": "event", "data": event})
        return event

    def event_list(self, limit: int = 200) -> list[dict]:
        return list(itertools.islice(self.events, limit))

    def set_snapshot(self, snapshot: dict) -> None:
        self.snapshot = snapshot
        self.publish({"type": "state", "data": snapshot})


class Poller:
    """Polls aria2 on an interval and drives the rule engine."""

    def __init__(
        self,
        rpc: Aria2RPC,
        store: Store,
        supervisor,
        rules,
        interval: float = 1.0,
        idle_interval: float = 5.0,
    ):
        self.rpc = rpc
        self.store = store
        self.supervisor = supervisor
        self.rules = rules
        self.interval = max(0.25, float(interval))
        #: Used when nothing is downloading *and* no UI is connected. Rules only
        #: ever act on live downloads, so slowing down here costs nothing.
        self.idle_interval = max(self.interval, float(idle_interval))
        #: gid -> recent (timestamp, completedLength) samples, used to derive a
        #: responsive speed without aria2's long smoothing window.
        self._progress: dict[str, deque[tuple[float, int]]] = {}
        #: name -> callable returning extra snapshot sections
        self.extras: dict[str, Any] = {}
        #: callables handed each finished snapshot (e.g. the history recorder)
        self.observers: list[Any] = []
        self._task: asyncio.Task | None = None
        self._wake = asyncio.Event()
        self._fail_streak = 0
        self._idle = False

    def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self.run())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None

    def poke(self) -> None:
        """Force an immediate refresh (after a mutating command)."""
        self._idle = False
        self._wake.set()

    @property
    def current_interval(self) -> float:
        return self.idle_interval if self._idle else self.interval

    def _is_idle(self, snapshot: dict) -> bool:
        """Nothing to watch and nobody watching: back off the tick.

        A connected UI always gets the full rate, and so does any download that
        is running, waiting or paused — those are what rules judge.
        """
        if self.store.has_subscribers:
            return False
        counts = snapshot.get("counts") or {}
        live = (counts.get("active", 0) + counts.get("waiting", 0) + counts.get("paused", 0))
        return live == 0

    async def run(self) -> None:
        last = time.monotonic()
        while True:
            try:
                now = time.monotonic()
                dt = now - last
                last = now
                snapshot = await self.poll_once()
                if snapshot is not None:
                    await self.rules.evaluate(snapshot, dt)
                    snapshot["rules"] = self.rules.public_state()
                    for name, provider in self.extras.items():
                        try:
                            snapshot[name] = provider()
                        except Exception as exc:  # a bad extra must not stop polling
                            snapshot[name] = {"error": str(exc)}
                    for observer in self.observers:
                        try:
                            observer(snapshot)
                        except Exception as exc:  # bookkeeping must not stop polling
                            self.store.add_event("error", f"Observer failed: {exc}")
                    self.store.set_snapshot(snapshot)
                    self._idle = self._is_idle(snapshot)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self._fail_streak += 1
                if self._fail_streak in (1, 5) or self._fail_streak % 30 == 0:
                    self.store.add_event("error", f"Poll failed: {exc}")
            try:
                await asyncio.wait_for(self._wake.wait(), timeout=self.current_interval)
            except asyncio.TimeoutError:
                pass
            else:
                self._wake.clear()

    def _measure_speed(self, row: dict, now: float) -> None:
        """Add `measuredSpeed`: bytes actually written, over a short window.

        aria2's own `downloadSpeed` is a long moving average, so it keeps
        reporting a healthy figure for several seconds after the bytes stop
        arriving, and ramps up slowly at the start. `completedLength` moves as
        soon as data lands, so its delta reflects reality.

        The window spans several samples rather than one tick: aria2 completes
        data in piece-sized chunks, so a single 1s delta can read zero for a
        download that is merely slow, and a stall detector must not be fooled by
        that. A ~3s window is still far more responsive than aria2's own.
        """
        gid = row["gid"]
        samples = self._progress.get(gid)
        if samples is None:
            samples = self._progress[gid] = deque(maxlen=SPEED_SAMPLES)
        row["measuredSpeed"] = None
        if samples:
            oldest_ts, oldest_done = samples[0]
            elapsed = now - oldest_ts
            delta = row["completed"] - oldest_done
            if delta < 0:
                # The file was restarted or truncated; the window is meaningless.
                samples.clear()
            elif elapsed >= MIN_SPEED_WINDOW:
                row["measuredSpeed"] = int(delta / elapsed)
        samples.append((now, row["completed"]))

    async def poll_once(self) -> dict | None:
        results = await self.rpc.multicall(
            [
                ("aria2.tellActive", [STATUS_KEYS]),
                ("aria2.tellWaiting", [0, 1000, STATUS_KEYS]),
                ("aria2.tellStopped", [0, 1000, STATUS_KEYS]),
                ("aria2.getGlobalStat", []),
            ]
        )
        self._fail_streak = 0
        active, waiting, stopped, stat = (results + [None] * 4)[:4]
        now = time.time()
        downloads: list[dict] = []
        for bucket, queued in ((active, False), (waiting, True), (stopped, False)):
            for offset, item in enumerate(bucket or []):
                row = normalize(item)
                if queued:
                    row["queuePosition"] = offset
                self._measure_speed(row, now)
                downloads.append(row)
        # Forget downloads that have gone away, so the map cannot grow forever.
        live = {d["gid"] for d in downloads if d["gid"]}
        for gone in [gid for gid in self._progress if gid not in live]:
            del self._progress[gone]
        stat = stat or {}
        counts = {
            "active": len(active or []),
            "waiting": len([d for d in (waiting or []) if d.get("status") == "waiting"]),
            "paused": len([d for d in (waiting or []) if d.get("status") == "paused"]),
            "stopped": len(stopped or []),
            "error": len([d for d in (stopped or []) if d.get("status") == "error"]),
        }
        return {
            "ts": time.time(),
            "downloads": downloads,
            "global": {
                "downloadSpeed": _int(stat.get("downloadSpeed")),
                "uploadSpeed": _int(stat.get("uploadSpeed")),
                "numActive": _int(stat.get("numActive")),
                "numWaiting": _int(stat.get("numWaiting")),
                "numStopped": _int(stat.get("numStopped")),
                "numStoppedTotal": _int(stat.get("numStoppedTotal")),
            },
            "counts": counts,
            "aria2": self.supervisor.status(),
            "rules": {},
        }
