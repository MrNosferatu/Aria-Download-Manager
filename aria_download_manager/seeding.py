"""Download-only torrents: take from the swarm, give back as little as possible.

aria2 has no switch for this, so it is assembled from what it does have:

* ``seed-time=0`` ends a torrent the moment it finishes, instead of seeding
  until ``seed-ratio``. Set on a running seeder it stops that one too (aria2
  restarts it internally and it lands as complete, file untouched).
* An upload cap of 1 B/s while the torrent is still downloading. It cannot be
  zero: aria2 reads 0 as "unlimited". BitTorrent peers favour those who give
  back, so a torrent with few seeders may download slower like this.

Globally the setting lives in the manager's own config (``torrent.download_only``),
not in aria2's options: aria2 can set ``seed-time`` but never unset it again
while running, so turning the setting off could not be expressed as an aria2
option edit. The manager instead caps aria2's overall upload, stamps both
options on every download it adds, and stops any seeder that slips through.

To the UIs it looks like one more option, ``download-only``, so the settings
forms need no special case.
"""

from __future__ import annotations

import asyncio
from typing import Any

#: The lowest upload limit aria2 accepts that is not "unlimited".
UPLOAD_FLOOR = "1"
#: aria2 cannot unset seed-time, so "no time limit" is a time never reached
#: (ten years, in minutes). Seeding then ends on seed-ratio, as if unset.
NO_SEED_TIME = "5256000"
#: The pseudo-option the UIs read and write.
KEY = "download-only"

DOWNLOAD_ONLY = {"seed-time": "0", "max-upload-limit": UPLOAD_FLOOR}


def is_download_only(options: dict) -> bool:
    """Does this download's option set mean download-only?"""
    return str(options.get("seed-time")) == "0" and str(options.get("max-upload-limit")) == UPLOAD_FLOOR


def truthy(value: Any) -> bool:
    return str(value).strip().lower() in ("true", "1", "yes", "on")


class DownloadOnly:
    def __init__(self, cfg, rpc, on_event):
        self.cfg = cfg
        self.rpc = rpc
        self.on_event = on_event
        #: gids already told to stop seeding, so one tick's call is not repeated
        #: every tick while aria2 restarts the download.
        self._stopping: set[str] = set()
        #: gid -> True for torrents kept seeding on purpose (file priorities
        #: holding one open for its next tier). Set by the owner of that.
        self.exempt = lambda gid: False

    @property
    def enabled(self) -> bool:
        return bool(self.cfg.get("torrent.download_only", False))

    def configured_upload_limit(self) -> str:
        return str(self.cfg.get("aria2.options", {}).get("max-overall-upload-limit") or "0")

    # ---- adding -----------------------------------------------------------
    def prepare(self, options: dict | None) -> dict:
        """Options for a new download: the pseudo-option resolved into aria2's.

        An explicit ``download-only`` from the add form wins; otherwise the
        global setting decides. Harmless on plain HTTP downloads, and it is what
        a .torrent fetched over HTTP or a magnet's real download inherits.
        """
        options = dict(options or {})
        wanted = options.pop(KEY, None)
        if truthy(wanted) if wanted is not None else self.enabled:
            for key, value in DOWNLOAD_ONLY.items():
                options.setdefault(key, value)
        return options

    # ---- per download -----------------------------------------------------
    def translate(self, options: dict) -> dict:
        """Resolve ``download-only`` in a per-download option edit."""
        options = dict(options)
        wanted = options.pop(KEY, None)
        if wanted is None:
            return options
        if truthy(wanted):
            options.update(DOWNLOAD_ONLY)
        else:
            configured = self.cfg.get("aria2.options", {})
            options["seed-time"] = str(configured.get("seed-time") or NO_SEED_TIME)
            if str(options.get("max-upload-limit", UPLOAD_FLOOR)) == UPLOAD_FLOOR:
                options["max-upload-limit"] = str(configured.get("max-upload-limit") or "0")
        return options

    # ---- global -----------------------------------------------------------
    async def apply(self) -> None:
        """Make aria2's overall upload cap match the setting."""
        limit = UPLOAD_FLOOR if self.enabled else self.configured_upload_limit()
        await self.rpc.change_global_option({"max-overall-upload-limit": limit})

    async def set(self, enabled: bool) -> None:
        # A hand-written "torrent:" with nothing under it parses as None.
        for holder in (self.cfg.data, self.cfg._user):
            if not isinstance(holder.get("torrent"), dict):
                holder["torrent"] = {}
            holder["torrent"]["download_only"] = enabled
        self.cfg.save()
        await self.apply()
        self._stopping.clear()
        self.on_event("info", "Torrents: download only" if enabled else "Torrents: seeding allowed")

    def public_state(self) -> dict:
        return {"downloadOnly": self.enabled}

    def observe(self, snapshot: dict) -> None:
        """Stop any torrent that is seeding while the setting is on.

        Covers torrents added before it was switched on, and anything added
        around the manager. New ones already carry seed-time=0 and never seed.
        """
        live = set()
        for row in snapshot.get("downloads", []):
            gid = row.get("gid")
            live.add(gid)
            if not (self.enabled and row.get("seeder") and row.get("status") == "active"):
                continue
            if gid in self._stopping or self.exempt(gid):
                continue
            self._stopping.add(gid)
            asyncio.get_running_loop().create_task(self._stop_seeding(gid, row.get("name", gid)))
        self._stopping &= live

    async def _stop_seeding(self, gid: str, name: str) -> None:
        try:
            await self.rpc.change_option(gid, dict(DOWNLOAD_ONLY))
            self.on_event("info", f"Stopped seeding {name} (download only)", gid=gid)
        except Exception as exc:
            self._stopping.discard(gid)
            self.on_event("error", f"Could not stop seeding {name}: {exc}", gid=gid)
