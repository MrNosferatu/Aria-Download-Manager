"""Persistent record of finished downloads.

aria2's session file only stores downloads that are *unfinished* — that is what
makes resume work, but it means completed downloads vanish from the list on the
next restart, and `aria2.purgeDownloadResult` erases them even sooner.

So the manager keeps its own record: every download it observes reaching a final
state is written to a JSON file that survives restarts, aria2 crashes and purges.
Nothing here affects downloading; it is bookkeeping, plus enough detail (the URL)
to queue something again. A finished torrent also keeps its file list (path,
size, whether it was chosen) and a magnet link, fetched once by the manager
(``set_files``), so its detail can show the files it skipped and fetch them
later without downloading the finished ones twice.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

from .config import Config, expand

FINAL_STATES = ("complete", "error", "removed")

#: Kept from the recorded entry when a poll rewrites it: the file list and how
#: to add the torrent again are fetched once, not carried by the snapshot.
DETAIL_KEYS = ("files", "magnet", "files_gid")


class History:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.entries: dict[str, dict[str, Any]] = {}
        #: Keys the user deleted. aria2 still lists those downloads in its own
        #: results, so without this the next poll would immediately re-import
        #: them and deleting would look like it did nothing.
        self.dismissed: dict[str, float] = {}
        self._dirty = False
        self._last_save = 0.0
        #: Torrent entries whose file list is still to be fetched (see set_files).
        self.pending_files: set[str] = set()
        self.load()

    # ---- config ----------------------------------------------------------
    @property
    def enabled(self) -> bool:
        return bool(self.cfg.get("history.enabled", True))

    @property
    def path(self) -> Path:
        return expand(
            self.cfg.get("history.file")
            or "~/.local/share/aria-download-manager/history.json"
        )

    @property
    def max_entries(self) -> int:
        return max(0, int(self.cfg.get("history.max_entries", 2000) or 0))

    # ---- persistence -----------------------------------------------------
    def load(self) -> None:
        if not self.path.is_file():
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        from .state import METADATA_PREFIX

        for entry in data.get("entries", []):
            key = entry.get("key") or entry.get("gid")
            if not key:
                continue
            # Recorded by an older build, before a magnet's metadata fetch was
            # told apart from the torrent it goes on to fetch.
            if str(entry.get("name", "")).startswith(METADATA_PREFIX) or str(key).startswith(METADATA_PREFIX):
                self._dirty = True
                continue
            self.entries[key] = entry
        self.dismissed = {
            str(k): float(v or 0) for k, v in (data.get("dismissed") or {}).items()
        }

    def save(self, force: bool = False) -> None:
        if not self._dirty:
            return
        # Coalesce writes: a busy queue would otherwise rewrite this every tick.
        if not force and time.time() - self._last_save < 5.0:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            ordered = sorted(
                self.entries.values(), key=lambda e: e.get("finished_at", 0), reverse=True
            )
            if self.max_entries:
                ordered = ordered[: self.max_entries]
                self.entries = {e["key"]: e for e in ordered}
            # Keep the tombstone list bounded; oldest dismissals fall off first.
            if len(self.dismissed) > 5000:
                keep = sorted(self.dismissed.items(), key=lambda kv: kv[1], reverse=True)
                self.dismissed = dict(keep[:5000])
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(
                json.dumps({"entries": ordered, "dismissed": self.dismissed}, indent=1),
                encoding="utf-8",
            )
            tmp.replace(self.path)
            self._dirty = False
            self._last_save = time.time()
        except OSError:
            pass  # history is a nicety; never break downloading over it

    # ---- observation -----------------------------------------------------
    def observe(self, snapshot: dict) -> None:
        """Record any download that has reached a final state.

        Keyed by path (or gid as a fallback) so that re-downloading the same file
        updates one row instead of piling up duplicates across aria2 restarts,
        which hand out fresh GIDs.
        """
        if not self.enabled:
            return
        for download in snapshot.get("downloads", []):
            if download.get("isMetadata"):
                continue  # the wait before a torrent, not a download to record
            key = download.get("path") or download.get("gid")
            if not key:
                continue
            if download.get("status") not in FINAL_STATES:
                # Downloading this file again clears its tombstone, so the fresh
                # run gets recorded when it finishes.
                if self.dismissed.pop(key, None) is not None:
                    self._dirty = True
                continue
            if key in self.dismissed:
                continue
            existing = self.entries.get(key)
            entry = {
                "key": key,
                "gid": download.get("gid", ""),
                "name": download.get("name", ""),
                "status": download.get("status", ""),
                "total": download.get("total", 0),
                "completed": download.get("completed", 0),
                "dir": download.get("dir", ""),
                "path": download.get("path", ""),
                "url": download.get("firstUri", ""),
                "isTorrent": download.get("isTorrent", False),
                "infoHash": download.get("infoHash", ""),
                "error": download.get("errorMessage") or "",
                "finished_at": (existing or {}).get("finished_at") or time.time(),
                "first_seen": (existing or {}).get("first_seen") or time.time(),
                "added_at": download.get("addedAt")
                or (existing or {}).get("added_at")
                or (existing or {}).get("first_seen")
                or time.time(),
            }
            for extra in DETAIL_KEYS:
                if existing and extra in existing:
                    entry[extra] = existing[extra]
            # A torrent's files, fetched once per finished run of it.
            if entry["isTorrent"] and entry["status"] == "complete" and entry.get("files_gid") != entry["gid"]:
                self.pending_files.add(key)
            if existing != entry:
                self.entries[key] = entry
                self._dirty = True
        self.save()

    def set_files(self, key: str, gid: str, files: list[dict], magnet: str = "") -> None:
        """Keep a finished torrent's files and how to add it again.

        `files` are aria2's getFiles shape (index, path, length,
        completedLength, selected); stored slimmer. A magnet already recorded
        is kept when none is given.
        """
        entry = self.entries.get(key)
        self.pending_files.discard(key)
        if not entry:
            return
        kept = {f["index"]: f.get("level") for f in entry.get("files") or [] if f.get("level") is not None}
        entry["files"] = [
            {
                "index": int(f.get("index") or i + 1),
                "path": f.get("path", ""),
                "length": int(f.get("length") or 0),
                "completed": int(f.get("completedLength") or 0),
                "selected": str(f.get("selected", "true")).lower() == "true",
            }
            for i, f in enumerate(files)
        ]
        # A priority the engine reports (qBittorrent) wins; else the one a
        # fetch asked for is kept across the refetch.
        for f, source in zip(entry["files"], files):
            level = source.get("priority") if source.get("priority") is not None else kept.get(f["index"])
            if level is not None:
                f["level"] = int(level)
        if magnet:
            entry["magnet"] = magnet
        entry["files_gid"] = gid
        self._dirty = True
        self.save()

    def set_levels(self, key: str, levels: dict[int, int]) -> None:
        """Keep the priorities a fetch asked for, so the detail shows them."""
        entry = self.get(key)
        if not entry:
            return
        for f in entry.get("files") or []:
            if f["index"] in levels:
                f["level"] = int(levels[f["index"]])
        self._dirty = True
        self.save()

    def detail(self, key: str) -> dict | None:
        """One entry with its files checked against the disk, for its detail."""
        entry = self.get(key)
        if not entry:
            return None
        out = dict(entry, file_exists=self._file_exists(entry))
        out["files"] = [dict(f, exists=self._exists(f.get("path", ""))) for f in entry.get("files") or []]
        return out

    @staticmethod
    def _exists(path: str) -> bool:
        try:
            return bool(path) and os.path.exists(path)
        except OSError:
            return False

    # ---- access ----------------------------------------------------------
    def list(self, limit: int = 200, status: str | None = None) -> list[dict]:
        rows = sorted(
            self.entries.values(), key=lambda e: e.get("finished_at", 0), reverse=True
        )
        if status:
            rows = [row for row in rows if row.get("status") == status]
        rows = rows[: max(1, limit)]
        # Checked on read rather than stored: a recorded file can be moved or
        # deleted long after it was written, and the stored row would go stale.
        # Only the page being returned is stat-ed.
        return [dict(row, file_exists=self._file_exists(row)) for row in rows]

    @staticmethod
    def _file_exists(row: dict) -> bool | None:
        """True/False for a row with a path, None when there is nothing to check."""
        path = row.get("path") or ""
        if not path:
            return None
        try:
            return os.path.exists(path)
        except OSError:
            return False

    def get(self, key: str) -> dict | None:
        if entry := self.entries.get(key):
            return entry
        return next((e for e in self.entries.values() if e.get("gid") == key), None)

    def remove(self, key: str) -> bool:
        entry = self.get(key)
        if not entry:
            return False
        self.entries.pop(entry["key"], None)
        self.dismissed[entry["key"]] = time.time()
        self._dirty = True
        self.save(force=True)
        return True

    def clear(self) -> int:
        """Drop every entry, and remember them so polling cannot bring them back."""
        count = len(self.entries)
        now = time.time()
        for key in self.entries:
            self.dismissed[key] = now
        self.entries.clear()
        self._dirty = True
        self.save(force=True)
        return count

    def summary(self) -> dict:
        rows = self.entries.values()
        return {
            "enabled": self.enabled,
            "count": len(self.entries),
            "completed": sum(1 for r in rows if r.get("status") == "complete"),
            "bytes": sum(int(r.get("completed") or 0) for r in rows),
            "dismissed": len(self.dismissed),
            "file": str(self.path),
        }
