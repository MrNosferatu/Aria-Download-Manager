"""Per-file priority for torrents, on top of aria2's plain file selection.

aria2 can only select or deselect a torrent's files (``select-file``); it has
no priorities. So the manager runs them as tiers: of the files the user wants,
only the highest-priority unfinished ones are selected. When those are done the
next tier is added, and so on down to Normal. "Do not download" is never
selected. Unlike qBittorrent, where priority only weights piece choice, a lower
tier here does not start until every higher one has finished.

Between tiers aria2 sees every selected file done and would end the download,
and a finished download cannot have its selection widened. So while lower tiers
are pending the torrent is told to keep seeding (``seed-ratio=0``, a
``seed-time`` never reached); at the boundary it sits as a seeder for a tick
until the next tier is selected. Once the last tier is running, its real
seeding options go back: download-only ones, or the configured ones.

Checked against real aria2c 1.37: a torrent held like this and then given a
wider ``select-file`` resumes downloading, keeping the files it already has.
"""

from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path

from . import seeding

SKIP, NORMAL, HIGH, MAXIMUM = 0, 1, 2, 3
LEVELS = (SKIP, NORMAL, HIGH, MAXIMUM)

#: Keep seeding, whatever the ratio, until the next tier is selected.
HOLD = {"seed-ratio": "0.0", "seed-time": seeding.NO_SEED_TIME}

#: Final states: the entry has done its job.
FINAL_STATES = ("complete", "error", "removed")
FORGET_AFTER = 7 * 86400


def _same(a, b) -> bool:
    """aria2 echoes "0.0" as set, but compare numbers as numbers anyway."""
    try:
        return float(a) == float(b)
    except (TypeError, ValueError):
        return str(a) == str(b)


def plan(files: list[dict], levels: dict[str, int]) -> tuple[list[int], bool]:
    """Which file indices to select now, and whether lower tiers are waiting.

    ``files`` is aria2's getFiles answer; ``levels`` maps index -> level.
    """
    wanted = [f for f in files if levels.get(str(f["index"]), NORMAL) > SKIP]
    level = lambda f: levels.get(str(f["index"]), NORMAL)  # noqa: E731
    unfinished = [f for f in wanted if int(f.get("completedLength") or 0) < int(f.get("length") or 0)]
    if not unfinished:
        return sorted(int(f["index"]) for f in wanted), False
    tier = max(level(f) for f in unfinished)
    chosen = sorted(int(f["index"]) for f in wanted if level(f) >= tier)
    waiting = any(level(f) < tier for f in unfinished)
    return chosen, waiting


class FilePriorities:
    def __init__(self, path: Path, rpc, cfg, download_only, on_event):
        self.path = Path(path)
        self.rpc = rpc
        self.cfg = cfg
        self.download_only = download_only
        self.on_event = on_event
        #: gid -> {"levels": {index: level}, "download_only": bool,
        #:          "waiting": bool, "seen": ts}
        self.entries: dict[str, dict] = {}
        self._busy: set[str] = set()
        self._dirty = False
        self.load()

    # ---- persistence ------------------------------------------------------
    def load(self) -> None:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        for gid, entry in (data.get("entries") or {}).items():
            if isinstance(entry, dict) and isinstance(entry.get("levels"), dict):
                self.entries[str(gid)] = entry

    def save(self) -> None:
        if not self._dirty:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"entries": self.entries}), encoding="utf-8")
            tmp.replace(self.path)
            self._dirty = False
        except OSError:
            pass

    # ---- queries ----------------------------------------------------------
    def has(self, gid: str) -> bool:
        return gid in self.entries

    def holding(self, gid: str) -> bool:
        """Is this torrent being kept alive for a lower tier?"""
        return bool(self.entries.get(gid, {}).get("waiting"))

    def levels(self, gid: str, files: list[dict]) -> dict[str, int]:
        """Each file's level: stored, or read off aria2's selection."""
        stored = self.entries.get(gid, {}).get("levels")
        if stored:
            return {str(f["index"]): int(stored.get(str(f["index"]), NORMAL)) for f in files}
        return {str(f["index"]): NORMAL if f.get("selected") == "true" else SKIP for f in files}

    def download_only_for(self, gid: str) -> bool | None:
        entry = self.entries.get(gid)
        return None if entry is None else bool(entry.get("download_only"))

    # ---- changes ----------------------------------------------------------
    async def set(self, gid: str, levels: dict) -> dict:
        clean = {str(k): int(v) for k, v in levels.items() if int(v) in LEVELS}
        if not any(v > SKIP for v in clean.values()):
            raise ValueError("pick at least one file to download")
        entry = self.entries.get(gid)
        if entry is None:
            options = await self.rpc.get_option(gid)
            entry = self.entries[gid] = {
                "download_only": self.download_only.enabled or seeding.is_download_only(options),
            }
        entry["levels"] = clean
        entry["seen"] = time.time()
        self._dirty = True
        self.save()
        return await self.enforce(gid)

    async def set_download_only(self, gid: str, enabled: bool) -> None:
        self.entries[gid]["download_only"] = enabled
        self._dirty = True
        self.save()
        await self.enforce(gid)

    def _seeding_options(self, entry: dict, waiting: bool) -> dict:
        if waiting:
            options = dict(HOLD)
            if entry.get("download_only") or self.download_only.enabled:
                options["max-upload-limit"] = seeding.UPLOAD_FLOOR
            return options
        if entry.get("download_only") or self.download_only.enabled:
            return dict(seeding.DOWNLOAD_ONLY)
        configured = self.cfg.get("aria2.options", {})
        return {
            "seed-time": str(configured.get("seed-time") or seeding.NO_SEED_TIME),
            "seed-ratio": str(configured.get("seed-ratio") or "1.0"),
        }

    async def enforce(self, gid: str) -> dict:
        """Bring aria2's selection and seeding options in line with the plan."""
        entry = self.entries.get(gid)
        if entry is None:
            return {}
        files, options = await self.rpc.multicall(
            [("aria2.getFiles", [gid]), ("aria2.getOption", [gid])]
        )
        if not files or len(files) < 2:
            return {}  # a magnet still fetching metadata has nothing to order
        chosen, waiting = plan(files, entry["levels"])
        change: dict = {}
        current = sorted(int(f["index"]) for f in files if f.get("selected") == "true")
        if chosen != current:
            change["select-file"] = ",".join(str(i) for i in chosen)
        for key, value in self._seeding_options(entry, waiting).items():
            if not _same((options or {}).get(key), value):
                change[key] = value
        if entry.get("waiting") != waiting:
            entry["waiting"] = waiting
            self._dirty = True
        if change:
            # One call: on a running torrent every change here restarts it, and
            # aria2 resumes from its control file, so the files it has stay.
            await self.rpc.change_option(gid, change)
            if "select-file" in change:
                self.on_event("info", f"Files for {gid}: now fetching {change['select-file']}", gid=gid)
        self.save()
        return change

    # ---- polling ----------------------------------------------------------
    def observe(self, snapshot: dict) -> None:
        now = time.time()
        live = {}
        for row in snapshot.get("downloads", []):
            live[row.get("gid")] = row
        for gid in list(self.entries):
            entry = self.entries[gid]
            row = live.get(gid)
            if row is None:
                if now - entry.get("seen", now) > FORGET_AFTER:
                    del self.entries[gid]
                    self._dirty = True
                continue
            entry["seen"] = now
            if row.get("status") in FINAL_STATES:
                if entry.get("waiting"):
                    entry["waiting"] = False
                    self._dirty = True
                continue
            if row.get("status") == "active" and gid not in self._busy:
                self._busy.add(gid)
                asyncio.get_running_loop().create_task(self._enforce_quietly(gid))
        self.save()

    async def _enforce_quietly(self, gid: str) -> None:
        try:
            await self.enforce(gid)
        except Exception as exc:
            self.on_event("error", f"File priorities for {gid}: {exc}", gid=gid)
        finally:
            self._busy.discard(gid)
