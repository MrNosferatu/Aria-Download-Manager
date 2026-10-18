"""qBittorrent as the torrent engine, next to aria2c for everything else.

aria2 can only select or deselect a torrent's files; qBittorrent (libtorrent)
has real per-file priorities, sequential download, first/last-piece priority
and a far more current BitTorrent stack. So torrents — magnets, .torrent files,
and .torrent links — go to a qbittorrent-nox the manager runs (or one you
already run), and every other download stays with aria2c.

To the UIs a qBittorrent torrent is one more row in the same snapshot, shaped
like an aria2 one, with a gid of ``qb-<infohash>`` and ``engine: qbittorrent``.
The API routes any call for such a gid here, so the front-ends need almost no
special cases.

Talks to qBittorrent's Web API v2. A managed instance gets its own profile with
authentication bypassed for localhost, so there is no password to configure;
an external one is reached with ``qbittorrent.username``/``password``. Both the
4.x API (pause/resume) and 5.x (stop/start) are spoken.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import json
import os
import re
import shutil
import time
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, urlsplit

import aiohttp

from .config import Config, expand, stringify
from .seeding import truthy

ENGINE = "qbittorrent"
PREFIX = "qb-"

#: The UIs' four levels (0 skip .. 3 maximum) and qBittorrent's own numbers.
LEVEL_TO_QB = {0: 0, 1: 1, 2: 6, 3: 7}

#: qBittorrent's eta for "never".
ETA_INFINITE = 8640000

#: Upload cap while a download-only torrent is still downloading. qBittorrent
#: reads 0 as unlimited; 1 KiB/s is the lowest its own UI can express.
UPLOAD_FLOOR = 1024

#: Pseudo-options the UIs read and write for a qBittorrent torrent.
SEQUENTIAL = "sequential-download"
FIRST_LAST = "first-last-piece-first"

DOWNLOADING = {"downloading", "forcedDL", "metaDL", "forcedMetaDL", "stalledDL",
               "checkingDL", "allocating", "moving", "checkingResumeData", "checkingUP"}
SEEDING = {"uploading", "stalledUP", "forcedUP"}
QUEUED = {"queuedDL", "queuedUP"}
STOPPED_DL = {"pausedDL", "stoppedDL"}
STOPPED_UP = {"pausedUP", "stoppedUP"}
FAILED = {"error", "missingFiles"}
METADATA = {"metaDL", "forcedMetaDL"}


class QBError(Exception):
    def __init__(self, message: str, status: int = 0):
        self.status = status
        self.message = message
        super().__init__(message)


# --------------------------------------------------------------------------
# small pure helpers
# --------------------------------------------------------------------------
def is_gid(gid: str) -> bool:
    return str(gid or "").startswith(PREFIX)


def gid_for(info_hash: str) -> str:
    return PREFIX + info_hash.lower()


def hash_of(gid: str) -> str:
    return gid[len(PREFIX):].lower()


def to_qb_priority(level: int) -> int:
    return LEVEL_TO_QB.get(int(level), 1)


def from_qb_priority(prio: int) -> int:
    prio = int(prio or 0)
    if prio <= 0:
        return 0
    if prio >= 7:
        return 3
    if prio >= 6:
        return 2
    return 1


def is_magnet(uri: str) -> bool:
    return str(uri).lower().startswith("magnet:")


def is_torrent_url(uri: str) -> bool:
    try:
        parts = urlsplit(uri)
    except ValueError:
        return False
    return parts.scheme in ("http", "https") and parts.path.lower().endswith(".torrent")


def magnet_hash(uri: str) -> str:
    """The info hash qBittorrent will key a magnet by, or "" if there is none."""
    try:
        query = parse_qs(urlsplit(uri).query)
    except ValueError:
        return ""
    v2 = ""
    for xt in query.get("xt", []):
        lower = xt.lower()
        if lower.startswith("urn:btih:"):
            value = xt[9:]
            if len(value) == 40 and re.fullmatch(r"[0-9a-fA-F]{40}", value):
                return value.lower()
            if len(value) == 32:
                with contextlib.suppress(ValueError, base64.binascii.Error):
                    return base64.b32decode(value.upper()).hex()
        elif lower.startswith("urn:btmh:1220") and len(xt) >= 13 + 64:
            # A v2 multihash (sha2-256); qBittorrent shows its first 40 digits.
            v2 = xt[13:13 + 40].lower()
    return v2


def _bend(data: bytes, i: int) -> int:
    """Index just past the bencoded value that starts at ``i``."""
    c = data[i:i + 1]
    if c == b"i":
        return data.index(b"e", i) + 1
    if c in (b"l", b"d"):
        i += 1
        while data[i:i + 1] != b"e":
            if not data[i:i + 1]:
                raise ValueError("truncated")
            i = _bend(data, i)
        return i + 1
    if c.isdigit():
        colon = data.index(b":", i)
        return colon + 1 + int(data[i:colon])
    raise ValueError(f"bad bencode at {i}")


def _dict_items(data: bytes):
    """(key, start, end) of each entry of the bencoded dict ``data``."""
    if data[:1] != b"d":
        raise ValueError("not a dictionary")
    i = 1
    while data[i:i + 1] != b"e":
        colon = data.index(b":", i)
        size = int(data[i:colon])
        key = data[colon + 1:colon + 1 + size]
        i = colon + 1 + size
        end = _bend(data, i)
        yield key, i, end
        i = end


def torrent_hash(data: bytes) -> str:
    """Info hash of a .torrent file the way qBittorrent reports it.

    v1 and hybrid torrents: SHA-1 of the info dict. v2-only: its SHA-256,
    cut to 40 digits like qBittorrent's own id.
    """
    for key, start, end in _dict_items(data):
        if key == b"info":
            info = data[start:end]
            keys = {k for k, _, _ in _dict_items(info)}
            if b"pieces" in keys:
                return hashlib.sha1(info).hexdigest()
            return hashlib.sha256(info).hexdigest()[:40]
    raise ValueError("no info dictionary")


def looks_like_torrent(data: bytes) -> bool:
    try:
        torrent_hash(data)
        return True
    except (ValueError, IndexError):
        return False


def parse_speed(value: Any) -> int:
    """aria2-style speed ("0", "500K", "2M", "1048576") -> bytes per second."""
    text = str(value or "0").strip().upper().rstrip("B").rstrip("/S")
    if not text:
        return 0
    scale = 1
    if text[-1] in "KMG":
        scale = {"K": 1024, "M": 1024 ** 2, "G": 1024 ** 3}[text[-1]]
        text = text[:-1]
    try:
        return max(0, int(float(text) * scale))
    except ValueError:
        return 0


def bucketize(states: list[int], buckets: int = 256) -> list[int]:
    """qBittorrent piece states (0 missing, 1 downloading, 2 done) -> 0-100 per bucket."""
    if not states:
        return []
    values = [100 if s == 2 else 50 if s == 1 else 0 for s in states]
    buckets = max(1, min(buckets, len(values)))
    size = len(values) / buckets
    out = []
    for index in range(buckets):
        start = int(index * size)
        end = max(start + 1, int((index + 1) * size))
        chunk = values[start:end]
        out.append(round(sum(chunk) / len(chunk)))
    return out


def status_of(state: str) -> str:
    if state in STOPPED_UP:
        return "complete"
    if state in STOPPED_DL:
        return "paused"
    if state in QUEUED:
        return "waiting"
    if state in FAILED:
        return "error"
    return "active"


def ensure_ini(path: Path, values: dict[str, dict[str, str]]) -> None:
    """Set keys in a QSettings ini file, keeping everything else in it."""
    lines = path.read_text(encoding="utf-8").splitlines() if path.is_file() else []
    pending = {section: dict(keys) for section, keys in values.items()}
    out: list[str] = []
    section = None

    def flush(name):
        for key, value in pending.pop(name, {}).items():
            out.append(f"{key}={value}")

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            flush(section)
            section = stripped[1:-1]
            out.append(line)
            continue
        if section in pending and "=" in line:
            key = line.split("=", 1)[0].strip()
            if key in pending[section]:
                out.append(f"{key}={pending[section].pop(key)}")
                continue
        out.append(line)
    flush(section)
    for name in list(pending):
        out.append(f"[{name}]")
        flush(name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(out) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------
# Web API client
# --------------------------------------------------------------------------
class QBClient:
    def __init__(self, host: str, port: int, username: str = "", password: str = "",
                 timeout: float = 20.0):
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.timeout = timeout
        self._session: aiohttp.ClientSession | None = None
        #: 5.x renamed pause/resume to stop/start; learnt on the first 404.
        self._legacy_verbs: bool | None = None

    @property
    def url(self) -> str:
        host = "127.0.0.1" if self.host in ("0.0.0.0", "::", "") else self.host
        return f"http://{host}:{self.port}"

    async def start(self) -> None:
        if self._session is None or self._session.closed:
            # The default jar drops cookies set by a bare IP, and the session
            # cookie (SID) comes from 127.0.0.1.
            self._session = aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=self.timeout),
                cookie_jar=aiohttp.CookieJar(unsafe=True),
            )

    async def close(self) -> None:
        if self._session and not self._session.closed:
            await self._session.close()
        self._session = None

    async def login(self) -> None:
        if not self.username:
            raise QBError("qBittorrent wants a login: set qbittorrent.username and password", 403)
        text, status = await self._raw("POST", "auth/login",
                                       form={"username": self.username, "password": self.password})
        if status != 200 or text.strip() != "Ok.":
            raise QBError("qBittorrent rejected the username or password", 403)

    async def _raw(self, method: str, path: str, params=None, form=None, data=None):
        await self.start()
        assert self._session is not None
        async with self._session.request(method, f"{self.url}/api/v2/{path}",
                                         params=params, data=data if data is not None else form) as resp:
            return await resp.text(), resp.status

    async def request(self, method: str, path: str, params=None, form=None, data=None,
                      json_reply: bool = False) -> Any:
        text, status = await self._raw(method, path, params, form, data)
        if status == 403 and self.username:
            await self.login()
            text, status = await self._raw(method, path, params, form, data)
        if status == 403:
            raise QBError("qBittorrent refused the request (login needed)", 403)
        if status == 404:
            raise QBError(f"qBittorrent has no {path} (or no such torrent)", 404)
        if status >= 400:
            raise QBError(f"qBittorrent answered {status} to {path}: {text.strip()[:200]}", status)
        if json_reply:
            return json.loads(text) if text else None
        return text

    # ---- reading ----------------------------------------------------------
    async def version(self) -> str:
        return (await self.request("GET", "app/version")).strip()

    async def torrents(self, hashes: list[str] | None = None) -> list[dict]:
        params = {"hashes": "|".join(hashes)} if hashes else None
        return await self.request("GET", "torrents/info", params=params, json_reply=True) or []

    async def transfer(self) -> dict:
        return await self.request("GET", "transfer/info", json_reply=True) or {}

    async def properties(self, h: str) -> dict:
        return await self.request("GET", "torrents/properties", params={"hash": h}, json_reply=True) or {}

    async def files(self, h: str) -> list[dict]:
        return await self.request("GET", "torrents/files", params={"hash": h}, json_reply=True) or []

    async def trackers(self, h: str) -> list[dict]:
        return await self.request("GET", "torrents/trackers", params={"hash": h}, json_reply=True) or []

    async def peers(self, h: str) -> dict:
        reply = await self.request("GET", "sync/torrentPeers", params={"hash": h, "rid": 0},
                                   json_reply=True) or {}
        return reply.get("peers") or {}

    async def piece_states(self, h: str) -> list[int]:
        return await self.request("GET", "torrents/pieceStates", params={"hash": h},
                                  json_reply=True) or []

    async def preferences(self) -> dict:
        return await self.request("GET", "app/preferences", json_reply=True) or {}

    # ---- writing ----------------------------------------------------------
    async def set_preferences(self, prefs: dict) -> None:
        await self.request("POST", "app/setPreferences", form={"json": json.dumps(prefs)})

    async def add(self, fields: dict[str, str], torrent: bytes | None = None,
                  filename: str = "file.torrent") -> None:
        form = aiohttp.FormData()
        for key, value in fields.items():
            form.add_field(key, str(value))
        if torrent is not None:
            form.add_field("torrents", torrent, filename=filename or "file.torrent",
                           content_type="application/x-bittorrent")
        text = await self.request("POST", "torrents/add", data=form)
        if text.strip() == "Fails.":
            raise QBError("qBittorrent refused the torrent (not a valid torrent?)", 415)

    async def _verb(self, new: str, old: str, hashes: list[str]) -> None:
        form = {"hashes": "|".join(hashes) or "all"}
        if self._legacy_verbs is not True:
            try:
                await self.request("POST", f"torrents/{new}", form=form)
                self._legacy_verbs = False
                return
            except QBError as exc:
                if exc.status != 404 or self._legacy_verbs is False:
                    raise
                self._legacy_verbs = True
        await self.request("POST", f"torrents/{old}", form=form)

    async def stop(self, hashes: list[str]) -> None:
        await self._verb("stop", "pause", hashes)

    async def resume(self, hashes: list[str]) -> None:
        await self._verb("start", "resume", hashes)

    async def delete(self, hashes: list[str], delete_files: bool) -> None:
        await self.request("POST", "torrents/delete", form={
            "hashes": "|".join(hashes), "deleteFiles": "true" if delete_files else "false"})

    async def file_priority(self, h: str, ids: list[int], prio: int) -> None:
        await self.request("POST", "torrents/filePrio", form={
            "hash": h, "id": "|".join(str(i) for i in ids), "priority": str(prio)})

    async def share_limits(self, hashes: list[str], ratio: float, minutes: int,
                           inactive: int = -2) -> None:
        # qBittorrent 5.2 refuses the call without shareLimitAction; older
        # versions ignore it. "Default" keeps the global setting's action.
        await self.request("POST", "torrents/setShareLimits", form={
            "hashes": "|".join(hashes), "ratioLimit": str(ratio),
            "seedingTimeLimit": str(minutes), "inactiveSeedingTimeLimit": str(inactive),
            "shareLimitAction": "Default"})

    async def upload_limit(self, hashes: list[str], limit: int) -> None:
        await self.request("POST", "torrents/setUploadLimit",
                           form={"hashes": "|".join(hashes), "limit": str(limit)})

    async def download_limit(self, hashes: list[str], limit: int) -> None:
        await self.request("POST", "torrents/setDownloadLimit",
                           form={"hashes": "|".join(hashes), "limit": str(limit)})

    async def simple(self, path: str, hashes: list[str]) -> None:
        """Endpoints that take only hashes: toggles, queue moves, recheck..."""
        await self.request("POST", f"torrents/{path}", form={"hashes": "|".join(hashes)})

    async def set_location(self, hashes: list[str], location: str) -> None:
        await self.request("POST", "torrents/setLocation",
                           form={"hashes": "|".join(hashes), "location": location})

    async def shutdown(self) -> None:
        await self.request("POST", "app/shutdown")


# --------------------------------------------------------------------------
# process supervision
# --------------------------------------------------------------------------
class QBSupervisor:
    """Runs qbittorrent-nox (``qbittorrent.managed``) or attaches to one."""

    def __init__(self, cfg: Config, client: QBClient, on_event: Callable[..., None],
                 on_ready: Callable[[], Any] | None = None):
        self.cfg = cfg
        self.client = client
        self.on_event = on_event
        self.on_ready = on_ready
        self.proc: asyncio.subprocess.Process | None = None
        self.adopted = False
        self.version = ""
        self.ready = False
        self.last_error = ""
        self.restarts = 0
        self._monitor_task: asyncio.Task | None = None
        self._stopping = False

    @property
    def managed(self) -> bool:
        return bool(self.cfg.get("qbittorrent.managed", True))

    def binary(self) -> str | None:
        name = str(self.cfg.get("qbittorrent.binary", "qbittorrent-nox"))
        return shutil.which(name) or (name if Path(name).is_file() else None)

    @property
    def wanted(self) -> bool:
        """Should torrents go to qBittorrent at all?"""
        engine = str(self.cfg.get("torrent.engine", "auto")).lower()
        if engine == "aria2":
            return False
        if engine == "qbittorrent" or not self.managed:
            return True
        return self.binary() is not None  # auto: whenever it is installed

    @property
    def profile(self) -> Path:
        return expand(self.cfg.get("qbittorrent.profile"))

    def status(self) -> dict:
        return {
            "wanted": self.wanted,
            "managed": self.managed,
            "running": self.ready,
            "adopted": self.adopted,
            "pid": self.proc.pid if self.proc and self.proc.returncode is None else None,
            "version": self.version,
            "url": self.client.url,
            "restarts": self.restarts,
            "last_error": self.last_error,
        }

    def _write_profile(self) -> None:
        conf = self.profile / "qBittorrent" / "config" / "qBittorrent.conf"
        ensure_ini(conf, {
            # 4.x waits on stdin for this otherwise; 5.x reads the same key.
            "LegalNotice": {"Accepted": "true"},
            "Preferences": {
                "WebUI\\Address": str(self.cfg.get("qbittorrent.host", "127.0.0.1")),
                "WebUI\\Port": str(int(self.cfg.get("qbittorrent.port", 8089))),
                # The Web UI only listens on localhost, the same trust boundary as
                # aria2's RPC; a password would have nowhere safe to live.
                "WebUI\\LocalHostAuth": "false",
            },
        })

    async def _probe(self) -> bool:
        try:
            self.version = await asyncio.wait_for(self.client.version(), 5)
            return True
        except Exception:
            return False

    async def start(self) -> None:
        self._stopping = False
        if not self.wanted:
            return
        timeout = float(self.cfg.get("qbittorrent.startup_timeout", 30.0))
        if not self.managed:
            await self._wait_ready(timeout)
            self.on_event("info", f"Attached to qBittorrent {self.version} for torrents")
        elif await self._probe():
            self.adopted = True
            self.on_event("info", f"Adopted the qBittorrent {self.version} already running "
                                  f"on port {self.client.port}")
        else:
            binary = self.binary()
            if not binary:
                raise QBError("qbittorrent-nox not found. Install it (Arch: sudo pacman -S "
                              "qbittorrent-nox) or set torrent.engine: aria2")
            self._write_profile()
            # One that cannot bind its port (an old instance still shutting
            # down) is stopped and started again, a couple of times.
            for attempt in range(3):
                try:
                    await self._spawn(binary)
                    await self._wait_ready(timeout)
                    break
                except QBError:
                    if attempt == 2:
                        raise
                    await asyncio.sleep(1.0)
            self.on_event("info", f"qBittorrent {self.version} ready for torrents "
                                  f"(pid {self.proc.pid if self.proc else '?'})")
            self._monitor_task = asyncio.create_task(self._monitor())
        await self._became_ready()

    async def _became_ready(self) -> None:
        self.ready = True
        self.last_error = ""
        if self.on_ready:
            try:
                await self.on_ready()
            except Exception as exc:
                self.on_event("warn", f"Could not apply settings to qBittorrent: {exc}")

    async def _port_free(self, seconds: float = 15.0) -> bool:
        """Wait until nothing answers on the Web UI port (an old one has quit)."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                _, writer = await asyncio.wait_for(
                    asyncio.open_connection(self.client.host, self.client.port), 1.0)
            except (OSError, asyncio.TimeoutError):
                return True
            writer.close()
            await asyncio.sleep(0.3)
        return False

    async def _spawn(self, binary: str) -> None:
        # A qBittorrent still shutting down (the manager restarted) holds the
        # port: the new one would run on without a Web UI, and the old one
        # could even answer the readiness check before it goes.
        await self._port_free()
        argv = [binary, f"--profile={self.profile}",
                f"--webui-port={int(self.cfg.get('qbittorrent.port', 8089))}"]
        self.proc = await asyncio.create_subprocess_exec(
            *argv, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE, start_new_session=True)
        asyncio.create_task(self._drain())

    async def _drain(self) -> None:
        proc = self.proc
        if proc is None or proc.stderr is None:
            return
        while raw := await proc.stderr.readline():
            line = raw.decode("utf-8", "replace").rstrip()
            if line:
                self.last_error = line
                self.on_event("warn", line, source="qbittorrent")
                # Running without its Web UI is no use to the manager: stop it,
                # and it is started again once the port is free.
                if "Unable to bind" in line and proc.returncode is None:
                    with contextlib.suppress(ProcessLookupError):
                        proc.terminate()

    async def _wait_ready(self, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        last: Exception | None = None
        while time.monotonic() < deadline:
            if self.proc is not None and self.proc.returncode is not None:
                raise QBError(f"qbittorrent-nox exited during startup (code {self.proc.returncode})"
                              + (f": {self.last_error}" if self.last_error else ""))
            try:
                self.version = await self.client.version()
                return
            except QBError as exc:
                if exc.status == 403 and self.client.username:
                    await self.client.login()
                    continue
                last = exc
            except Exception as exc:  # refused while it boots
                last = exc
            await asyncio.sleep(0.3)
        raise QBError(f"qBittorrent Web API at {self.client.url} not reachable: {last}")

    async def _monitor(self) -> None:
        backoff = 1.0
        while not self._stopping and self.proc is not None:
            code = await self.proc.wait()
            if self._stopping:
                return
            self.ready = False
            self.last_error = f"qbittorrent-nox exited with code {code}"
            self.on_event("error", self.last_error)
            if not self.cfg.get("qbittorrent.restart_on_exit", True):
                return
            self.restarts += 1
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)
            try:
                await self._spawn(self.binary() or "qbittorrent-nox")
                await self._wait_ready(float(self.cfg.get("qbittorrent.startup_timeout", 30.0)))
                self.on_event("info", f"qBittorrent restarted (pid {self.proc.pid})")
                backoff = 1.0
                await self._became_ready()
            except Exception as exc:
                self.on_event("error", f"qBittorrent restart failed: {exc}")

    async def stop(self) -> None:
        self._stopping = True
        if self._monitor_task:
            self._monitor_task.cancel()
            self._monitor_task = None
        owned = self.managed and (self.proc is not None or self.adopted)
        if owned and self.cfg.get("qbittorrent.stop_on_exit", True):
            with contextlib.suppress(Exception):
                await self.client.shutdown()
            if self.proc is not None and self.proc.returncode is None:
                try:
                    await asyncio.wait_for(self.proc.wait(), timeout=10)
                except asyncio.TimeoutError:
                    self.proc.terminate()
                    with contextlib.suppress(asyncio.TimeoutError):
                        await asyncio.wait_for(self.proc.wait(), timeout=5)
        self.ready = False
        self.proc = None
        self.adopted = False
        await self.client.close()


# --------------------------------------------------------------------------
# the engine: what the API and the poller talk to
# --------------------------------------------------------------------------
class QBEngine:
    def __init__(self, cfg: Config, on_event: Callable[..., None]):
        self.cfg = cfg
        self.on_event = on_event
        self.client = QBClient(
            host=str(cfg.get("qbittorrent.host", "127.0.0.1")),
            port=int(cfg.get("qbittorrent.port", 8089)),
            username=str(cfg.get("qbittorrent.username", "") or ""),
            password=str(cfg.get("qbittorrent.password", "") or ""),
        )
        self.supervisor = QBSupervisor(cfg, self.client, on_event, on_ready=self.apply_settings)
        #: hash -> number of files, learnt once the metadata is there.
        self._file_counts: dict[str, int] = {}
        #: hashes already told to stop seeding (download only).
        self._stopping: set[str] = set()
        #: (options, torrent bytes) -> options: the manager's folder sorting.
        self.prepare_torrent: Callable[[dict, bytes], dict] | None = None
        self._fail_streak = 0

    # ---- lifecycle --------------------------------------------------------
    @property
    def ready(self) -> bool:
        return self.supervisor.ready

    async def start(self) -> None:
        if not self.supervisor.wanted:
            return
        try:
            await self.supervisor.start()
        except Exception as exc:
            self.supervisor.last_error = str(exc)
            self.on_event("error", f"qBittorrent unavailable, torrents go to aria2c: {exc}")

    async def stop(self) -> None:
        await self.supervisor.stop()

    def public_state(self) -> dict:
        return self.supervisor.status()

    # ---- settings shared with the rest of the manager -----------------------
    @property
    def download_only(self) -> bool:
        return bool(self.cfg.get("torrent.download_only", False))

    def _configured(self, key: str) -> str:
        return str((self.cfg.get("aria2.options", {}) or {}).get(key) or "0")

    async def apply_settings(self) -> None:
        """Bring qBittorrent's own preferences in line with the manager's."""
        prefs: dict[str, Any] = {
            "dl_limit": parse_speed(self._configured("max-overall-download-limit")),
        }
        folder = stringify(self.cfg.get("aria2.options.dir", "") or "")
        if folder:
            prefs["save_path"] = folder
        prefs.update(self._seeding_prefs())
        await self.client.set_preferences(prefs)

    def _seeding_prefs(self) -> dict:
        if self.download_only:
            # Stop (pause, on 4.x) the moment a torrent completes, and upload as
            # little as possible while it downloads.
            return {"max_ratio_enabled": True, "max_ratio": 0,
                    "max_seeding_time_enabled": True, "max_seeding_time": 0,
                    "max_ratio_act": 0, "up_limit": UPLOAD_FLOOR}
        ratio = float(self._configured("seed-ratio") or 0)
        return {"max_ratio_enabled": ratio > 0, "max_ratio": ratio if ratio > 0 else -1,
                "max_seeding_time_enabled": False, "max_ratio_act": 0,
                "up_limit": parse_speed(self._configured("max-overall-upload-limit"))}

    async def set_global_limits(self, options: dict) -> None:
        prefs: dict[str, Any] = {}
        if "max-overall-download-limit" in options:
            prefs["dl_limit"] = parse_speed(options["max-overall-download-limit"])
        if "max-overall-upload-limit" in options and not self.download_only:
            prefs["up_limit"] = parse_speed(options["max-overall-upload-limit"])
        if "dir" in options:
            prefs["save_path"] = str(options["dir"])
        if "seed-ratio" in options and not self.download_only:
            prefs.update(self._seeding_prefs())
        if prefs and self.ready:
            await self.client.set_preferences(prefs)

    async def set_download_only(self) -> None:
        self._stopping.clear()
        if self.ready:
            await self.client.set_preferences(self._seeding_prefs())

    # ---- snapshot ---------------------------------------------------------
    def _row(self, t: dict) -> dict:
        h = str(t.get("hash", "")).lower()
        state = str(t.get("state", ""))
        status = status_of(state)
        total = int(t.get("size") or 0)
        done = int(t.get("completed") or 0)
        speed = int(t.get("dlspeed") or 0)
        eta = int(t.get("eta") or 0)
        ratio_limit = float(t.get("ratio_limit", -2))
        time_limit = int(t.get("seeding_time_limit", -2))
        if ratio_limit == -2 and time_limit == -2:
            download_only = self.download_only
        else:
            download_only = ratio_limit == 0 and time_limit == 0
        error = None
        if state == "missingFiles":
            error = "The torrent's files are missing"
        elif state == "error":
            error = "qBittorrent reported an I/O error (see its log)"
        row = {
            "gid": gid_for(h),
            "engine": ENGINE,
            "status": status,
            "name": t.get("name") or h,
            "isMetadata": state in METADATA,
            "total": total,
            "completed": done,
            "uploaded": int(t.get("uploaded") or 0),
            "progress": round(done / total * 100, 2) if total else 0.0,
            "downloadSpeed": speed,
            "uploadSpeed": int(t.get("upspeed") or 0),
            "connections": int(t.get("num_seeds") or 0) + int(t.get("num_leechs") or 0),
            "numSeeders": int(t.get("num_seeds") or 0),
            "seeder": state in SEEDING or state == "queuedUP",
            "dir": t.get("save_path", ""),
            "eta": eta if speed > 0 and 0 < eta < ETA_INFINITE else None,
            "numFiles": self._file_counts.get(h, 0),
            "numPieces": 0,
            "pieceLength": 0,
            "isTorrent": True,
            "infoHash": h,
            "errorCode": "qbittorrent" if error else None,
            "errorMessage": error,
            "following": None,
            "followedBy": [],
            "path": t.get("content_path") or "",
            "firstUri": t.get("magnet_uri") or "",
            "downloadOnly": download_only,
            "sequential": bool(t.get("seq_dl")),
            "firstLastPiece": bool(t.get("f_l_piece_prio")),
            "qbState": state,
        }
        prio = int(t.get("priority") or 0)
        if status == "waiting" and prio > 0:
            row["queuePosition"] = prio - 1
        return row

    async def poll(self) -> tuple[list[dict], dict] | None:
        """Rows for the snapshot plus qBittorrent's transfer totals, or None if down."""
        if not self.ready:
            return None
        try:
            torrents, transfer = await asyncio.gather(self.client.torrents(), self.client.transfer())
        except Exception as exc:
            self._fail_streak += 1
            if self._fail_streak in (1, 5) or self._fail_streak % 30 == 0:
                self.on_event("error", f"qBittorrent poll failed: {exc}")
            return None
        self._fail_streak = 0
        # Learn file counts once the metadata is there (it never changes after).
        unknown = [str(t["hash"]).lower() for t in torrents
                   if str(t.get("hash", "")).lower() not in self._file_counts
                   and t.get("state") not in METADATA and int(t.get("total_size") or 0) > 0]
        if unknown:
            counts = await asyncio.gather(*(self.client.files(h) for h in unknown[:20]),
                                          return_exceptions=True)
            for h, files in zip(unknown, counts):
                if isinstance(files, list) and files:
                    self._file_counts[h] = len(files)
        live = {str(t.get("hash", "")).lower() for t in torrents}
        for gone in [h for h in self._file_counts if h not in live]:
            del self._file_counts[gone]
        rows = [self._row(t) for t in torrents]
        self._stop_seeders(rows)
        return rows, transfer

    def _stop_seeders(self, rows: list[dict]) -> None:
        """A download-only torrent found seeding is stopped.

        qBittorrent's share limits already stop new ones on completion; this
        catches torrents that predate the setting or were added around it.
        """
        live = set()
        for row in rows:
            h = row["infoHash"]
            live.add(h)
            if not (row["downloadOnly"] and row["seeder"] and h not in self._stopping):
                continue
            self._stopping.add(h)
            asyncio.get_running_loop().create_task(self._stop_seeding(h, row["name"]))
        self._stopping &= live

    async def _stop_seeding(self, h: str, name: str) -> None:
        try:
            await self.client.stop([h])
            self.on_event("info", f"Stopped seeding {name} (download only)", gid=gid_for(h))
        except Exception as exc:
            self._stopping.discard(h)
            self.on_event("error", f"Could not stop seeding {name}: {exc}", gid=gid_for(h))

    # ---- adding -----------------------------------------------------------
    def _add_fields(self, options: dict, paused: bool) -> dict[str, str]:
        fields: dict[str, str] = {}
        if options.get("dir"):
            fields["savepath"] = str(options["dir"])
        if options.get("out"):
            fields["rename"] = os.path.basename(str(options["out"]))
        if options.get("max-download-limit"):
            fields["dlLimit"] = str(parse_speed(options["max-download-limit"]))
        wanted = options.get("download-only")
        download_only = truthy(wanted) if wanted is not None else self.download_only
        if download_only:
            fields.update(ratioLimit="0", seedingTimeLimit="0", upLimit=str(UPLOAD_FLOOR))
        elif wanted is not None:
            # Explicitly allowed to seed while the global setting says otherwise.
            ratio = float(self._configured("seed-ratio") or 0)
            fields.update(ratioLimit=str(ratio if ratio > 0 else -1), seedingTimeLimit="-1")
        elif options.get("max-upload-limit"):
            fields["upLimit"] = str(parse_speed(options["max-upload-limit"]))
        if truthy(options.get(SEQUENTIAL, "")):
            fields["sequentialDownload"] = "true"
        if truthy(options.get(FIRST_LAST, "")):
            fields["firstLastPiecePrio"] = "true"
        if paused or truthy(options.get("pause", "")):
            fields["paused"] = fields["stopped"] = "true"
        elif truthy(options.get("pause-metadata", "")):
            # Fetch the file list, then wait for the user's choice.
            fields["stopCondition"] = "MetadataReceived"
        return fields

    async def _existing(self, h: str) -> bool:
        with contextlib.suppress(Exception):
            return bool(await self.client.torrents([h]))
        return False

    async def add_magnet(self, uri: str, options: dict, paused: bool = False,
                         existing: list[str] | None = None) -> str:
        h = magnet_hash(uri)
        if h and await self._existing(h):
            self.on_event("info", "That torrent is already in qBittorrent", gid=gid_for(h))
            if existing is not None:
                existing.append(gid_for(h))
            return gid_for(h)
        await self.client.add({"urls": uri, **self._add_fields(options, paused)})
        if not h:
            raise QBError("added to qBittorrent, but the magnet has no info hash to track it by")
        return gid_for(h)

    async def add_torrent(self, data: bytes, options: dict, paused: bool = False,
                          filename: str = "", existing: list[str] | None = None) -> str:
        """Add a .torrent; a torrent qBittorrent already has goes into ``existing``."""
        h = torrent_hash(data)
        if await self._existing(h):
            self.on_event("info", "That torrent is already in qBittorrent", gid=gid_for(h))
            if existing is not None:
                existing.append(gid_for(h))
            return gid_for(h)
        # A .torrent already has its file list: "wait for my choice" is a stop.
        paused = paused or truthy(options.get("pause-metadata", ""))
        if self.prepare_torrent:
            options = self.prepare_torrent(dict(options), data)
        await self.client.add(self._add_fields(options, paused), torrent=data,
                              filename=filename or f"{h}.torrent")
        return gid_for(h)

    @staticmethod
    async def fetch_torrent(url: str, headers: dict[str, str]) -> bytes | None:
        """Fetch a .torrent link with the browser's headers; None if it is not one.

        qBittorrent could fetch the URL itself, but without the page's cookie a
        private tracker's link answers with a login page.
        """
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(url, headers=headers, allow_redirects=True,
                                       timeout=aiohttp.ClientTimeout(total=30)) as res:
                    if res.status >= 400:
                        return None
                    data = await res.content.read(16 * 1024 * 1024)
        except (aiohttp.ClientError, asyncio.TimeoutError):
            return None
        return data if looks_like_torrent(data) else None

    # ---- per torrent ------------------------------------------------------
    async def _info(self, h: str) -> dict:
        found = await self.client.torrents([h])
        if not found:
            raise QBError(f"no torrent {h} in qBittorrent", 404)
        return found[0]

    async def detail(self, gid: str) -> dict:
        h = hash_of(gid)
        t = await self._info(h)
        props, files, trackers, peers, pieces = await asyncio.gather(
            self.client.properties(h), self.client.files(h), self.client.trackers(h),
            self.client.peers(h), self.client.piece_states(h), return_exceptions=True)
        props = props if isinstance(props, dict) else {}
        files = files if isinstance(files, list) else []
        trackers = trackers if isinstance(trackers, list) else []
        peers = peers if isinstance(peers, dict) else {}
        pieces = pieces if isinstance(pieces, list) else []
        row = self._row(t)
        save_path = t.get("save_path") or ""
        tracker_status = {0: "disabled", 1: "not contacted", 2: "working", 3: "updating",
                          4: "not working"}
        return {
            "engine": ENGINE,
            "status": {
                "gid": gid,
                "status": row["status"],
                "dir": save_path,
                "totalLength": str(row["total"]),
                "completedLength": str(row["completed"]),
                "uploadLength": str(row["uploaded"]),
                "downloadSpeed": str(row["downloadSpeed"]),
                "uploadSpeed": str(row["uploadSpeed"]),
                "connections": str(row["connections"]),
                "numSeeders": str(row["numSeeders"]),
                "infoHash": h,
                "numPieces": str(props.get("pieces_num") or len(pieces)),
                "pieceLength": str(props.get("piece_size") or 0),
                "errorCode": row["errorCode"],
                "errorMessage": row["errorMessage"],
                "bittorrent": {"info": {"name": row["name"]}, "comment": props.get("comment", "")},
                "qbState": row["qbState"],
                "ratio": t.get("ratio"),
            },
            "files": [
                {
                    "index": str(i + 1),
                    "path": os.path.join(save_path, f.get("name", "")),
                    "length": str(int(f.get("size") or 0)),
                    "completedLength": str(int(int(f.get("size") or 0) * float(f.get("progress") or 0))),
                    "selected": "true" if int(f.get("priority") or 0) > 0 else "false",
                    "priority": from_qb_priority(f.get("priority") or 0),
                    "waitingForTier": False,
                    "availability": f.get("availability"),
                }
                for i, f in enumerate(files)
            ],
            "uris": [
                {"uri": tr.get("url", ""), "status": tr.get("msg") or tracker_status.get(tr.get("status"), "")}
                for tr in trackers if not str(tr.get("url", "")).startswith("** [")
            ],
            "options": {
                "max-download-limit": str(max(0, int(t.get("dl_limit") or 0))),
                "max-upload-limit": str(max(0, int(t.get("up_limit") or 0))),
                "download-only": "true" if row["downloadOnly"] else "false",
                SEQUENTIAL: "true" if row["sequential"] else "false",
                FIRST_LAST: "true" if row["firstLastPiece"] else "false",
            },
            "servers": [],
            "peers": sorted(
                ({"ip": p.get("ip", ""), "port": p.get("port", 0), "client": p.get("client", ""),
                  "downloadSpeed": str(p.get("dl_speed") or 0), "uploadSpeed": str(p.get("up_speed") or 0),
                  "seeder": "true" if float(p.get("progress") or 0) >= 1 else "false",
                  "progress": p.get("progress")}
                 for p in peers.values()),
                key=lambda p: -int(p["downloadSpeed"]))[:60],
            "pieceMap": bucketize(pieces),
        }

    async def pause(self, gid: str) -> None:
        await self.client.stop([hash_of(gid)])

    async def resume(self, gid: str) -> None:
        await self.client.resume([hash_of(gid)])

    async def remove(self, gid: str, delete_files: bool) -> None:
        await self.client.delete([hash_of(gid)], delete_files)

    async def pause_all(self) -> None:
        if self.ready:
            await self.client.stop([])

    async def resume_all(self) -> None:
        if self.ready:
            await self.client.resume([])

    async def retry(self, gid: str) -> str:
        h = hash_of(gid)
        t = await self._info(h)
        if t.get("state") in FAILED:
            await self.client.simple("recheck", [h])
            detail = "rechecking its files"
        else:
            await self.client.simple("reannounce", [h])
            detail = "asking its trackers for peers again"
        await self.client.resume([h])
        return detail

    async def set_options(self, gid: str, options: dict) -> dict:
        h = hash_of(gid)
        t = await self._info(h)
        applied: dict[str, str] = {}
        if "max-download-limit" in options:
            await self.client.download_limit([h], parse_speed(options["max-download-limit"]))
            applied["max-download-limit"] = options["max-download-limit"]
        wanted = options.get("download-only")
        if wanted is not None:
            if truthy(wanted):
                await self.client.share_limits([h], 0, 0, 0)
                await self.client.upload_limit([h], UPLOAD_FLOOR)
            else:
                ratio = float(self._configured("seed-ratio") or 0)
                await self.client.share_limits([h], ratio if ratio > 0 else -1, -1, -1)
                await self.client.upload_limit([h], parse_speed(options.get("max-upload-limit", 0)))
                self._stopping.discard(h)
            applied["download-only"] = str(wanted)
        elif "max-upload-limit" in options:
            await self.client.upload_limit([h], parse_speed(options["max-upload-limit"]))
            applied["max-upload-limit"] = options["max-upload-limit"]
        for key, field, endpoint in ((SEQUENTIAL, "seq_dl", "toggleSequentialDownload"),
                                     (FIRST_LAST, "f_l_piece_prio", "toggleFirstLastPiecePrio")):
            if key in options and truthy(options[key]) != bool(t.get(field)):
                await self.client.simple(endpoint, [h])
                applied[key] = options[key]
        if options.get("dir"):
            await self.client.set_location([h], str(options["dir"]))
            applied["dir"] = options["dir"]
        return applied

    async def set_levels(self, gid: str, levels: dict[str, int]) -> dict:
        """File index (1-based, as the UIs send it) -> 0 skip .. 3 maximum."""
        h = hash_of(gid)
        groups: dict[int, list[int]] = {}
        for index, level in levels.items():
            level = int(level)
            if level not in LEVEL_TO_QB:
                raise ValueError(f"priority must be 0-3, got {level}")
            groups.setdefault(to_qb_priority(level), []).append(int(index) - 1)
        if not any(p > 0 for p in groups):
            raise ValueError("pick at least one file to download")
        state = str((await self._info(h)).get("state", ""))
        for prio, ids in groups.items():
            await self.client.file_priority(h, sorted(ids), prio)
        # A finished torrent that was just given files it does not have yet
        # stays stopped in qBittorrent ("pausedDL"); picking them means
        # wanting them, so it starts again. A torrent the user paused
        # mid-download is left as it is.
        if state in STOPPED_UP:
            files = await self.client.files(h)
            missing = [i for p, ids in groups.items() if p > 0 for i in ids
                       if i < len(files) and float(files[i].get("progress") or 0) < 1]
            if missing:
                self._stopping.discard(h)
                await self.client.resume([h])
                self.on_event("info", "Downloading the newly chosen files", gid=gid)
        return {str(i + 1): from_qb_priority(p) for p, ids in groups.items() for i in ids}

    async def select(self, gid: str, indices: list[int]) -> None:
        files = await self.client.files(hash_of(gid))
        chosen = set(int(i) for i in indices)
        await self.set_levels(gid, {str(i + 1): (1 if (i + 1) in chosen else 0)
                                    for i in range(len(files))})

    async def move(self, gid: str, pos: int, how: str) -> int:
        """aria2's changePosition, on qBittorrent's queue."""
        h = hash_of(gid)
        if how == "POS_END":
            await self.client.simple("bottomPrio", [h])
        elif how == "POS_SET" and pos <= 0:
            await self.client.simple("topPrio", [h])
        else:
            current = int((await self._info(h)).get("priority") or 0)
            steps = pos if how == "POS_CUR" else (pos + 1) - current
            for _ in range(abs(int(steps))):
                await self.client.simple("decreasePrio" if steps > 0 else "increasePrio", [h])
        return max(0, int((await self._info(h)).get("priority") or 1) - 1)
