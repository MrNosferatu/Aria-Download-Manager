"""When each download was added, and when it finished.

aria2 reports neither: `tellStatus` has no timestamps at all. So the manager
notes the first poll a GID appears in (added) and the first poll it is seen in a
final state (finished), and stamps both onto every row as `addedAt` and
`finishedAt`. That is what the UIs sort by.

GIDs survive an aria2c restart (the session file stores them), so the record is
kept on disk and a queued download keeps its place in "date added" order across
restarts. A GID that stops appearing is forgotten after a grace period rather
than at once: right after a restart aria2 briefly lists nothing, and dropping
everything then would restamp the whole queue as "just added".
"""

from __future__ import annotations

import json
import time
from pathlib import Path

FINAL_STATES = ("complete", "error", "removed")

#: How long a GID may go unseen before its record is dropped.
FORGET_AFTER = 7 * 86400


class Timeline:
    def __init__(self, path: Path):
        self.path = Path(path)
        #: gid -> {"added": ts, "finished": ts | None, "seen": ts}
        self.entries: dict[str, dict] = {}
        self._dirty = False
        self._last_save = 0.0
        self.load()

    def load(self) -> None:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        for gid, entry in (data.get("entries") or {}).items():
            if isinstance(entry, dict) and entry.get("added"):
                self.entries[str(gid)] = entry

    def save(self, force: bool = False) -> None:
        if not self._dirty:
            return
        # "seen" moves every tick; only a real change needs writing promptly.
        if not force and time.time() - self._last_save < 30.0:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"entries": self.entries}), encoding="utf-8")
            tmp.replace(self.path)
            self._dirty = False
            self._last_save = time.time()
        except OSError:
            pass  # ordering is a nicety; never break downloading over it

    def observe(self, snapshot: dict) -> None:
        """Stamp `addedAt` / `finishedAt` onto every row, recording new ones."""
        now = time.time()
        changed = False
        for row in snapshot.get("downloads", []):
            gid = row.get("gid")
            if not gid:
                continue
            entry = self.entries.get(gid)
            if entry is None:
                entry = self.entries[gid] = {"added": now, "finished": None}
                changed = True
            final = row.get("status") in FINAL_STATES
            if final and not entry.get("finished"):
                entry["finished"] = now
                changed = True
            elif not final and entry.get("finished"):
                # Back in the queue under the same GID: it has not finished yet.
                entry["finished"] = None
                changed = True
            entry["seen"] = now
            row["addedAt"] = entry["added"]
            row["finishedAt"] = entry.get("finished")
        stale = [g for g, e in self.entries.items() if now - e.get("seen", now) > FORGET_AFTER]
        for gid in stale:
            del self.entries[gid]
        self._dirty = True
        self.save(force=changed or bool(stale))
