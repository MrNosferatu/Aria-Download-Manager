"""The manager's API: routes and validation by FastAPI, run in-process and served
only over the IPC socket (see ipc.py). Nothing here listens on the network."""

from __future__ import annotations

import asyncio
import base64
import binascii
import os
import signal
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Callable

import aiohttp
from fastapi import Body, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import files as filetools
from . import media as mediatools
from .config import Config, stringify
from .mediajobs import MediaJobs
from .history import History
from .ipc import IPCServer, socket_path_for
from .rpc import DETAIL_KEYS, Aria2Error, Aria2RPC
from .rules import ACTIONS, SPEED_SOURCES, RuleEngine
from .state import Poller, Store, aria2_only
from .supervisor import Aria2Supervisor
from .timeline import Timeline
from . import priorities as priority
from . import qbittorrent as qbt
from . import routing as routing_mod
from . import seeding

VERSION = "1.1.0"

# --------------------------------------------------------------------------
# request models
# --------------------------------------------------------------------------
class AddRequest(BaseModel):
    uris: list[str] = Field(default_factory=list)
    url: str | None = None
    options: dict[str, Any] = Field(default_factory=dict)
    position: int | None = None
    paused: bool = False
    # False => each URI becomes its own download.
    # True  => all URIs are treated as mirrors of one file.
    mirrors: bool = False


class TorrentRequest(BaseModel):
    data: str  # base64 of the .torrent / .metalink file
    kind: str = "torrent"  # "torrent" | "metalink"
    filename: str | None = None
    uris: list[str] = Field(default_factory=list)
    options: dict[str, Any] = Field(default_factory=dict)
    position: int | None = None
    paused: bool = False


class OptionsRequest(BaseModel):
    options: dict[str, Any]


class PositionRequest(BaseModel):
    pos: int
    how: str = "POS_SET"  # POS_SET | POS_CUR | POS_END


class RulesRequest(BaseModel):
    rules: list[dict[str, Any]] | None = None
    enabled: bool | None = None
    #: aria2 | measured | hybrid — which speed figure rules judge by.
    speed_source: str | None = None


class FilePrioritiesRequest(BaseModel):
    #: file index (aria2's, 1-based) -> 0 skip, 1 normal, 2 high, 3 maximum
    levels: dict[str, int]


class RoutingRequest(BaseModel):
    enabled: bool | None = None
    folders: dict[str, str] | None = None
    extensions: dict[str, list[str]] | None = None


class SelectFilesRequest(BaseModel):
    indices: list[int]


class MediaProbeRequest(BaseModel):
    """Ask what a media URL can be downloaded as.

    The extension sends the manifest URL it saw go past on the network, plus the
    request headers that fetched it — a manifest behind a login needs the same
    cookie the player used, or the probe gets an error page instead.
    """

    url: str
    referer: str | None = None
    cookie: str | None = None
    user_agent: str | None = None
    #: What the response claimed to be, when the sniffer saw it.
    content_type: str | None = None
    title: str | None = None


class MediaDownloadRequest(BaseModel):
    url: str
    #: One of the ids from a probe. Omitted means "the best one".
    variant_id: str | None = None
    #: A probe result may be passed straight back so the server need not refetch.
    variant: dict[str, Any] | None = None
    filename: str | None = None
    dir: str | None = None
    referer: str | None = None
    cookie: str | None = None
    user_agent: str | None = None
    content_type: str | None = None
    title: str | None = None


class BulkRequest(BaseModel):
    """One action applied to a chosen set of downloads.

    Distinct from the /api/global/* endpoints, which always mean *everything*.
    """

    gids: list[str] = Field(default_factory=list)
    #: pause | resume | remove
    action: str
    #: remove only: also delete what the downloads left on disk.
    delete_files: bool = False
    force: bool = False


class HistoryKeyRequest(BaseModel):
    """History keys are filesystem paths, so they travel in the body, not the URL."""

    key: str


class IntakeRequest(BaseModel):
    """Deliberately lenient: the browser extension sends whatever the page gave it."""

    url: str | None = None
    urls: list[str] = Field(default_factory=list)
    filename: str | None = None
    dir: str | None = None
    referer: str | None = None
    cookie: str | None = None
    userAgent: str | None = None
    headers: dict[str, str] | list[str] = Field(default_factory=dict)
    options: dict[str, Any] = Field(default_factory=dict)
    paused: bool = False
    source: str | None = None


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def clean_options(options: dict[str, Any] | None) -> dict[str, Any]:
    """Drop blanks and coerce everything to aria2's string/list-of-string form."""
    out: dict[str, Any] = {}
    for key, value in (options or {}).items():
        key = str(key).strip().lstrip("-")
        if not key or value is None:
            continue
        if isinstance(value, str) and not value.strip():
            continue
        if isinstance(value, (list, tuple)):
            items = [stringify(v) for v in value if str(v).strip()]
            if items:
                out[key] = items
            continue
        out[key] = stringify(value)
    return out


def split_uris(*sources: Any) -> list[str]:
    uris: list[str] = []
    for source in sources:
        if not source:
            continue
        candidates = source if isinstance(source, (list, tuple)) else [source]
        for candidate in candidates:
            for line in str(candidate).replace("\r", "\n").split("\n"):
                line = line.strip()
                if line:
                    uris.append(line)
    seen: set[str] = set()
    return [u for u in uris if not (u in seen or seen.add(u))]


def piece_map(bitfield: str, num_pieces: int, buckets: int = 256) -> list[int]:
    """Downsample aria2's hex bitfield into 0-100 completion per bucket."""
    if not bitfield or num_pieces <= 0:
        return []
    bits: list[int] = []
    for char in bitfield:
        try:
            nibble = int(char, 16)
        except ValueError:
            continue
        bits.extend((nibble >> shift) & 1 for shift in (3, 2, 1, 0))
    bits = bits[:num_pieces]
    if not bits:
        return []
    buckets = max(1, min(buckets, len(bits)))
    size = len(bits) / buckets
    out: list[int] = []
    for index in range(buckets):
        start = int(index * size)
        end = max(start + 1, int((index + 1) * size))
        chunk = bits[start:end]
        out.append(round(sum(chunk) / len(chunk) * 100))
    return out


def decode_b64(data: str, what: str) -> str:
    payload = data.split(",", 1)[1] if data.startswith("data:") else data
    payload = payload.strip()
    try:
        base64.b64decode(payload, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(400, f"{what} is not valid base64: {exc}") from exc
    return payload


async def run(app: FastAPI, stop: asyncio.Event, started: Callable[[], None] | None = None) -> None:
    """Run the manager until `stop` is set.

    Takes the place of a web server: startup (the socket, aria2c, the poller) and
    shutdown are the app's lifespan, and there are no connections to serve other
    than the ones the socket accepts itself.
    """
    async with app.router.lifespan_context(app):
        if started:
            started()
        await stop.wait()


# --------------------------------------------------------------------------
# app factory
# --------------------------------------------------------------------------
def create_app(cfg: Config) -> FastAPI:
    rpc = Aria2RPC(
        host=str(cfg.get("aria2.rpc.host", "127.0.0.1")),
        port=int(cfg.get("aria2.rpc.port", 6800)),
        secret=str(cfg.get("aria2.rpc.secret", "")),
    )
    store = Store()
    supervisor = Aria2Supervisor(
        cfg, rpc, lambda level, message, **kw: store.add_event(level, message, **kw)
    )
    engine = RuleEngine(cfg, rpc, store)
    poller = Poller(
        rpc,
        store,
        supervisor,
        engine,
        float(cfg.get("poll_interval", 1.0)),
        float(cfg.get("poll_interval_idle", 5.0)),
    )
    download_only = seeding.DownloadOnly(
        cfg, rpc, lambda level, message, **kw: store.add_event(level, message, **kw))
    router = routing_mod.Router(
        cfg, rpc, lambda level, message, **kw: store.add_event(level, message, **kw))

    def prepare_add(options: dict, uris=None, torrent=None) -> dict:
        return router.apply(download_only.prepare(options), uris=uris, torrent=torrent)

    rpc.prepare_add = prepare_add

    def aria2_view(observer):
        """An observer that acts through aria2's RPC sees aria2's rows only."""
        return lambda snapshot: observer(aria2_only(snapshot))

    # Torrents go to qBittorrent when it is up (see qbittorrent.py).
    qb = qbt.QBEngine(cfg, lambda level, message, **kw: store.add_event(level, message, **kw))
    qb.prepare_torrent = lambda options, data: router.apply(options, torrent=data)
    poller.sources.append(qb.poll)
    poller.extras["qbittorrent"] = qb.public_state
    poller.observers.append(aria2_view(router.observe))
    poller.observers.append(aria2_view(download_only.observe))
    poller.extras["torrent"] = download_only.public_state
    # A magnet's metadata fetch has done its job the moment the real torrent
    # exists. aria2 keeps the finished husk in its stopped list, where it shows
    # as a completed download whose file is missing; drop it instead.
    cleared_metadata: set[str] = set()

    async def _drop_metadata(gid: str) -> None:
        try:
            await rpc.remove_result(gid)
        except Exception:
            cleared_metadata.discard(gid)  # try again on a later tick

    def forget_metadata(snapshot: dict) -> None:
        live = set()
        for row in snapshot.get("downloads", []):
            live.add(row.get("gid"))
            if not (row.get("isMetadata") and row.get("status") == "complete"):
                continue
            # Only once it has actually produced the torrent download.
            if not row.get("followedBy") or row["gid"] in cleared_metadata:
                continue
            cleared_metadata.add(row["gid"])
            asyncio.get_running_loop().create_task(_drop_metadata(row["gid"]))
        cleared_metadata.intersection_update(live)

    poller.observers.append(aria2_view(forget_metadata))
    history = History(cfg)
    file_priorities = priority.FilePriorities(
        history.path.parent / "priorities.json", rpc, cfg, download_only,
        lambda level, message, **kw: store.add_event(level, message, **kw))
    download_only.exempt = file_priorities.holding
    poller.observers.append(aria2_view(file_priorities.observe))
    # Before the history, so a recorded download carries its "added" time too.
    timeline = Timeline(history.path.parent / "timeline.json")
    poller.observers.append(timeline.observe)
    poller.observers.append(history.observe)
    media_jobs = MediaJobs(
        on_event=lambda level, message, **kw: store.add_event(level, message, **kw),
        max_parallel=int(cfg.get("media.max_parallel", 2) or 2),
    )
    # The poller already carries a hook for extra snapshot sections and nothing
    # had used it: media jobs ride along with every state frame, so both
    # front-ends see them without polling anything new.
    poller.extras["media"] = media_jobs.public_state

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # First, and fatal if it fails: the socket is the only way in, and a
        # second manager must find out before it touches aria2c.
        await ipc.start()
        await rpc.start()
        store.add_event("info", f"Aria Download Manager {VERSION} starting")
        try:
            await supervisor.start()
        except Exception as exc:
            supervisor.last_error = str(exc)
            store.add_event("error", f"aria2c unavailable: {exc}")
        # Say whether aria2c came up now, not after the first poll: against an
        # RPC port that never answers, that poll takes a full timeout to fail.
        store.set_snapshot({**store.snapshot, "ts": time.time(), "aria2": supervisor.status()})
        # A managed aria2c already got the cap on its command line; an adopted
        # or external one has to be told.
        if download_only.enabled:
            try:
                await download_only.apply()
            except Exception as exc:
                store.add_event("error", f"Could not cap torrent uploads: {exc}")
        await qb.start()
        poller.start()
        store.add_event("info", f"IPC socket listening at {ipc.path}")
        try:
            yield
        finally:
            store.publish({"type": "shutdown", "data": {"ok": True}})
            await ipc.stop()
            await media_jobs.shutdown()
            history.save(force=True)
            timeline.save(force=True)
            await poller.stop()
            await qb.stop()
            await supervisor.stop()
            await rpc.close()

    app = FastAPI(title="Aria Download Manager", version=VERSION, lifespan=lifespan)
    ipc = IPCServer(app, store, socket_path_for(cfg))
    app.state.cfg = cfg
    app.state.rpc = rpc
    app.state.store = store
    app.state.supervisor = supervisor
    app.state.engine = engine
    app.state.poller = poller
    app.state.history = history
    app.state.media_jobs = media_jobs
    app.state.ipc = ipc
    app.state.qb = qb

    @app.exception_handler(qbt.QBError)
    async def qbittorrent_error_handler(request: Request, exc: qbt.QBError):
        code = exc.status if exc.status in (400, 404, 409, 415) else 502
        return JSONResponse(status_code=code, content={"ok": False, "error": exc.message})

    @app.exception_handler(Aria2Error)
    async def aria2_error_handler(request: Request, exc: Aria2Error):
        return JSONResponse(
            status_code=502,
            content={"ok": False, "error": exc.message, "code": exc.code, "method": exc.method},
        )

    @app.exception_handler(aiohttp.ClientError)
    async def rpc_unreachable_handler(request: Request, exc: aiohttp.ClientError):
        """Distinguish "aria2 is down" from "aria2 replied with an HTTP error"."""
        if isinstance(exc, aiohttp.ClientResponseError):
            # We reached aria2; it just did not like this request.
            return JSONResponse(
                status_code=502,
                content={
                    "ok": False,
                    "error": f"aria2 replied HTTP {exc.status}: {exc.message}",
                },
            )
        hint = (
            "aria2c is not running."
            if supervisor.managed
            else f"No aria2c reachable at {rpc.url}."
        )
        detail = supervisor.last_error or str(exc)
        return JSONResponse(
            status_code=503,
            content={"ok": False, "error": f"{hint} {detail}".strip()},
        )

    # ---- meta ------------------------------------------------------------
    @app.get("/api/state")
    async def get_state():
        return store.snapshot

    @app.get("/api/config")
    async def get_config():
        return cfg.public()

    @app.post("/api/restart")
    async def restart_manager():
        """Exit so the service manager brings us back, rereading config.yaml."""

        async def bye():
            await asyncio.sleep(0.2)
            os.kill(os.getpid(), signal.SIGTERM)

        asyncio.create_task(bye())
        return {"ok": True, "restarting": True}

    @app.post("/api/aria2/restart")
    async def aria2_restart():
        await supervisor.restart()
        poller.poke()
        return {"ok": True, "status": supervisor.status()}

    @app.get("/api/log")
    async def get_log(limit: int = 200):
        return {"events": store.event_list(limit), "triggers": engine.trigger_log[:100]}

    # ---- adding ----------------------------------------------------------
    async def _add_to_qb(uris: list[str], options: dict, paused: bool,
                         headers: dict[str, str] | None = None,
                         maybe_torrent: bool = False) -> tuple[list[str], list[str]]:
        """Hand qBittorrent the torrents among ``uris``: (its gids, what is left for aria2).

        A .torrent link (with ``maybe_torrent``, any link the browser named as a
        .torrent file) is fetched here, with the browser's headers, and only
        goes to qBittorrent if it really is a torrent; anything else stays with
        aria2, as does everything while qBittorrent is not up.
        """
        if not qb.ready:
            return [], list(uris)
        gids: list[str] = []
        rest: list[str] = []
        for uri in uris:
            if qbt.is_magnet(uri):
                gids.append(await qb.add_magnet(uri, options, paused))
            elif ((maybe_torrent or qbt.is_torrent_url(uri))
                  and (data := await qb.fetch_torrent(uri, headers or {}))):
                name = os.path.basename(uri.split("?")[0])
                gids.append(await qb.add_torrent(data, options, paused, filename=name))
            else:
                rest.append(uri)
        return gids, rest

    async def _add_uris(req: AddRequest) -> dict:
        uris = split_uris(req.uris, req.url)
        if not uris:
            raise HTTPException(400, "no URI given")
        options = clean_options(req.options)
        if req.paused:
            options["pause"] = "true"
        qb_gids, uris = await _add_to_qb(uris, options, req.paused)
        if not uris:
            poller.poke()
            store.add_event("info", f"Queued {len(qb_gids)} torrent(s) in qBittorrent", gids=qb_gids)
            return {"ok": True, "gids": qb_gids}
        # A magnet says nothing about what it holds. With sorting on, hold the
        # torrent its metadata produces for the moment it takes to pick the
        # folder — moving it afterwards would strand the files aria2 has
        # already created. Someone who asked to choose files keeps their pause.
        chooses_files = "pause-metadata" in options
        hold = router.wants_paused_metadata(options, uris)
        if hold:
            options["pause-metadata"] = "true"
        gids: list[str] = []
        if req.mirrors:
            gids.append(await rpc.add_uri(uris, options, req.position))
        else:
            for index, uri in enumerate(uris):
                position = None if req.position is None else req.position + index
                gids.append(await rpc.add_uri([uri], dict(options), position))
        if hold or chooses_files:
            for gid in gids:
                router.expect(gid, resume=hold and not chooses_files)
        gids = qb_gids + gids
        poller.poke()
        store.add_event(
            "info",
            f"Queued {len(gids)} download(s)" + (" as mirrors" if req.mirrors else ""),
            gids=gids,
        )
        return {"ok": True, "gids": gids}

    @app.post("/api/downloads")
    async def add_downloads(req: AddRequest):
        return await _add_uris(req)

    @app.post("/api/downloads/file")
    async def add_file(req: TorrentRequest):
        payload = decode_b64(req.data, req.kind)
        options = clean_options(req.options)
        if req.paused:
            options["pause"] = "true"
        if req.kind == "metalink":
            gids = await rpc.add_metalink(payload, options, req.position)
        elif qb.ready:
            gids = [await qb.add_torrent(base64.b64decode(payload), options, req.paused,
                                         filename=req.filename or "")]
        else:
            gids = [await rpc.add_torrent(payload, req.uris, options, req.position)]
        poller.poke()
        store.add_event("info", f"Added {req.kind} {req.filename or ''}".strip(), gids=gids)
        return {"ok": True, "gids": gids}

    # ---- media streams ---------------------------------------------------
    #: A manifest is a text file listing streams; anything much larger than this
    #: is not a manifest, and slurping it would mean downloading the video into
    #: memory to find out.
    MANIFEST_LIMIT = 4 * 1024 * 1024

    def _media_headers(req) -> dict[str, str]:
        """The headers that made the browser's own request work.

        A stream behind a login is fetched with the page's cookie; without it a
        probe gets an error page and reports no variants at all.
        """
        headers: dict[str, str] = {}
        if getattr(req, "cookie", None):
            headers["Cookie"] = req.cookie
        if getattr(req, "referer", None):
            headers["Referer"] = req.referer
        if getattr(req, "user_agent", None):
            headers["User-Agent"] = req.user_agent
        return headers

    async def _probe_media(req) -> mediatools.Probe:
        kind = mediatools.kind_for(req.url, req.content_type or "")
        headers = _media_headers(req)

        if kind == "direct":
            # Nothing to parse: the URL is the file. A HEAD is enough to confirm
            # it is reachable and learn its type.
            content_type = req.content_type or ""
            try:
                async with aiohttp.ClientSession() as session:
                    async with session.head(req.url, headers=headers,
                                            allow_redirects=True,
                                            timeout=aiohttp.ClientTimeout(total=15)) as res:
                        content_type = res.headers.get("Content-Type", content_type)
            except (aiohttp.ClientError, asyncio.TimeoutError):
                pass
            probe = mediatools.parse_direct(req.url, content_type)
            probe.title = req.title or ""
            return probe

        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(req.url, headers=headers,
                                       allow_redirects=True,
                                       timeout=aiohttp.ClientTimeout(total=25)) as res:
                    if res.status >= 400:
                        raise HTTPException(
                            502, f"the stream host answered {res.status} for that manifest")
                    content_type = res.headers.get("Content-Type", req.content_type or "")
                    body = await res.content.read(MANIFEST_LIMIT)
        except aiohttp.ClientError as exc:
            raise HTTPException(502, f"could not fetch the manifest: {exc}") from exc
        except asyncio.TimeoutError as exc:
            raise HTTPException(504, "timed out fetching the manifest") from exc

        probe = mediatools.parse(body.decode("utf-8", "replace"), str(res.url), content_type)
        probe.title = req.title or ""
        return probe

    @app.post("/api/media/probe")
    async def media_probe(req: MediaProbeRequest):
        """What can be downloaded from this stream, and in what qualities."""
        probe = await _probe_media(req)
        return {"ok": True, **probe.as_dict(),
                "ffmpeg": bool(media_jobs.ffmpeg_path())}

    @app.post("/api/media/download")
    async def media_download(req: MediaDownloadRequest):
        """Queue a chosen variant.

        A progressive file is an ordinary download and goes to aria2 with
        everything else. A segmented stream cannot: it is a manifest, so it goes
        to ffmpeg, which fetches the segments and muxes them into one file.
        """
        variant = req.variant
        probe_title = req.title or ""
        if not variant:
            probe = await _probe_media(req)
            if not probe.variants:
                raise HTTPException(
                    422, probe.unsupported or "nothing downloadable in that stream")
            chosen = None
            if req.variant_id:
                chosen = next((v for v in probe.variants if v.id == req.variant_id), None)
                if chosen is None:
                    raise HTTPException(404, f"no variant {req.variant_id} in that stream")
            variant = (chosen or probe.variants[0]).as_dict()
            probe_title = probe_title or probe.title

        directory = req.dir or stringify(cfg.get("aria2.options.dir", "")) or str(Path.home() / "Downloads")

        if variant.get("kind") == "direct":
            options = {"dir": directory}
            if req.filename:
                options["out"] = req.filename
            headers = _media_headers(req)
            if headers.get("Referer"):
                options["referer"] = headers["Referer"]
            if headers.get("Cookie"):
                options["header"] = [f"Cookie: {headers['Cookie']}"]
            if headers.get("User-Agent"):
                options["user-agent"] = headers["User-Agent"]
            gid = await rpc.add_uri([variant["url"]], clean_options(options), None)
            poller.poke()
            store.add_event("info", f"Queued {req.filename or variant['url']}", gids=[gid])
            return {"ok": True, "kind": "direct", "gids": [gid]}

        if not media_jobs.ffmpeg_path():
            raise HTTPException(
                503,
                "ffmpeg is not installed. A segmented stream is a list of parts, "
                "and ffmpeg is what fetches them and muxes them into one file.")

        name = req.filename or mediatools.suggested_name(
            req.url, probe_title, variant.get("height"))
        if not name.lower().endswith((".mp4", ".mkv", ".webm", ".m4a")):
            name += ".mp4"
        job = media_jobs.start(variant, name, directory, _media_headers(req))
        return {"ok": True, "kind": "stream", "job": job.as_dict()}

    # ---- per-download ----------------------------------------------------
    @app.get("/api/download/{gid}")
    async def download_detail(gid: str):
        if qbt.is_gid(gid):
            return await qb.detail(gid)
        status = await rpc.tell_status(gid, DETAIL_KEYS)
        results = await rpc.multicall(
            [
                ("aria2.getFiles", [gid]),
                ("aria2.getUris", [gid]),
                ("aria2.getOption", [gid]),
                ("aria2.getServers", [gid]),
            ]
        )
        files, uris, options, servers = (results + [None] * 4)[:4]
        peers = None
        if status.get("bittorrent") and status.get("status") == "active":
            try:
                peers = await rpc.get_peers(gid)
            except Aria2Error:
                peers = None
        levels = file_priorities.levels(gid, files or [])
        files = [
            {
                **f,
                "priority": levels.get(str(f.get("index")), priority.NORMAL),
                # Wanted, but held back until the higher tiers finish.
                "waitingForTier": levels.get(str(f.get("index"))) != priority.SKIP
                and f.get("selected") != "true",
            }
            for f in (files or [])
        ]
        held = file_priorities.download_only_for(gid)
        if held is not None:
            held = held or download_only.enabled
        return {
            "status": status,
            "files": files,
            "uris": uris or [],
            "options": {
                **(options or {}),
                seeding.KEY: "true" if (held if held is not None else seeding.is_download_only(options or {}))
                else "false",
            },
            "servers": servers or [],
            "peers": (peers or [])[:60],
            "pieceMap": piece_map(
                status.get("bitfield", ""), int(status.get("numPieces") or 0)
            ),
        }

    @app.post("/api/download/{gid}/pause")
    async def pause(gid: str, force: bool = False):
        if qbt.is_gid(gid):
            await qb.pause(gid)
        else:
            await rpc.pause(gid, force=force)
        poller.poke()
        return {"ok": True}

    @app.post("/api/download/{gid}/resume")
    async def resume(gid: str):
        if qbt.is_gid(gid):
            await qb.resume(gid)
        else:
            await rpc.unpause(gid)
        poller.poke()
        return {"ok": True}

    async def _owned_paths(gid: str) -> tuple[list[str], list[str]]:
        """A download's file paths and the roots they may be deleted within.

        Read *before* the download is removed: once aria2 has dropped it, there
        is nothing left to ask about the files it wrote.
        """
        paths: list[str] = []
        roots: list[str] = []
        try:
            for entry in await rpc.get_files(gid):
                if path := entry.get("path"):
                    paths.append(path)
        except Aria2Error:
            pass
        try:
            status = await rpc.tell_status(gid, ["dir"])
            if own_dir := (status or {}).get("dir"):
                roots.append(own_dir)
        except Aria2Error:
            pass
        if global_dir := stringify(cfg.get("aria2.options.dir", "")):
            roots.append(global_dir)
        return paths, roots

    EMPTY_REMOVAL = {"deleted": [], "missing": [], "refused": [], "bytes": 0}

    async def _stop_and_delete(gid: str, force: bool, purge: bool) -> dict:
        """Stop a download, then delete what it wrote — strictly in that order.

        The paths have to be read before the download goes (aria2 forgets them),
        but the bytes can only be deleted after it has stopped: a still-running
        download simply rewrites its `.aria2` control file into the gap.
        """
        paths, roots = await _owned_paths(gid)
        await _remove_from_aria2(gid, force=force, purge=purge)
        if not paths:
            return dict(EMPTY_REMOVAL)
        return await asyncio.to_thread(filetools.delete, paths, roots)

    async def _remove_from_aria2(gid: str, force: bool, purge: bool) -> None:
        try:
            await rpc.remove(gid, force=force)
        except Aria2Error:
            # Already stopped: nothing to remove, only a result to purge.
            purge = True
        if purge:
            try:
                await rpc.remove_result(gid)
            except Aria2Error:
                pass

    @app.delete("/api/download/{gid}")
    async def remove(
        gid: str,
        force: bool = False,
        purge: bool = True,
        delete_files: bool = False,
    ):
        """Remove a download, optionally taking its bytes with it.

        aria2 never deletes anything itself, so without `delete_files` a removed
        download leaves its part file and `.aria2` control file on disk forever.
        """
        if qbt.is_gid(gid):
            # qBittorrent deletes its own files, and only its own.
            await qb.remove(gid, delete_files)
            poller.poke()
            return {"ok": True}
        if delete_files:
            removal = await _stop_and_delete(gid, force=force, purge=purge)
        else:
            removal = None
            await _remove_from_aria2(gid, force=force, purge=purge)
        poller.poke()
        if removal is None:
            return {"ok": True}
        if removal["deleted"]:
            store.add_event(
                "info",
                f"Removed and deleted {len(removal['deleted'])} file(s), "
                f"freeing {removal['bytes']} bytes",
            )
        for refusal in removal["refused"]:
            store.add_event(
                "warn", f"Could not delete {refusal['path']}: {refusal['reason']}"
            )
        return {"ok": True, "files": removal}

    @app.post("/api/downloads/bulk")
    async def bulk(req: BulkRequest):
        """Apply one action to a chosen set of downloads.

        Best-effort per gid: one failure does not abandon the rest, and the
        response says exactly which ones did not take.
        """
        if req.action not in ("pause", "resume", "remove"):
            raise HTTPException(400, "action must be pause, resume or remove")
        if not req.gids:
            raise HTTPException(400, "no gids given")

        done: list[str] = []
        failed: list[dict] = []
        removal_total = {"deleted": [], "missing": [], "refused": [], "bytes": 0}

        for gid in req.gids:
            try:
                if qbt.is_gid(gid):
                    if req.action == "pause":
                        await qb.pause(gid)
                    elif req.action == "resume":
                        await qb.resume(gid)
                    else:
                        await qb.remove(gid, req.delete_files)
                elif req.action == "pause":
                    await rpc.pause(gid, force=req.force)
                elif req.action == "resume":
                    await rpc.unpause(gid)
                elif req.delete_files:
                    one = await _stop_and_delete(gid, force=req.force, purge=True)
                    for key in ("deleted", "missing", "refused"):
                        removal_total[key].extend(one[key])
                    removal_total["bytes"] += one["bytes"]
                else:
                    await _remove_from_aria2(gid, force=req.force, purge=True)
                done.append(gid)
            except (Aria2Error, qbt.QBError) as exc:
                failed.append({"gid": gid, "error": str(exc)})

        poller.poke()
        verb = {"pause": "Paused", "resume": "Resumed", "remove": "Removed"}[req.action]
        message = f"{verb} {len(done)} download(s)"
        if req.delete_files and removal_total["deleted"]:
            message += (
                f", deleting {len(removal_total['deleted'])} file(s) "
                f"({removal_total['bytes']} bytes)"
            )
        if failed:
            message += f", {len(failed)} failed"
        store.add_event("info" if not failed else "warn", message)
        return {
            "ok": True,
            "done": done,
            "failed": failed,
            "files": removal_total if req.delete_files else None,
            "message": message,
        }

    @app.post("/api/download/{gid}/options")
    async def set_download_options(gid: str, req: OptionsRequest):
        options = clean_options(req.options)
        if qbt.is_gid(gid):
            applied = await qb.set_options(gid, options)
            if not applied:
                raise HTTPException(400, "none of those options apply to a qBittorrent torrent")
            poller.poke()
            return {"ok": True, "applied": applied}
        if file_priorities.has(gid) and seeding.KEY in options:
            # File priorities own this torrent's seeding options while it has
            # tiers to go; they apply download-only when the last tier runs.
            wanted = seeding.truthy(options.pop(seeding.KEY))
            await file_priorities.set_download_only(gid, wanted)
            if wanted:
                options.pop("max-upload-limit", None)  # the floor is applied with it
            if not options:
                poller.poke()
                return {"ok": True, "applied": {}}
        options = download_only.translate(options)
        if not options:
            raise HTTPException(400, "no options given")
        await rpc.change_option(gid, options)
        poller.poke()
        return {"ok": True, "applied": options}

    @app.post("/api/download/{gid}/position")
    async def set_position(gid: str, req: PositionRequest):
        if req.how not in ("POS_SET", "POS_CUR", "POS_END"):
            raise HTTPException(400, "how must be POS_SET, POS_CUR or POS_END")
        if qbt.is_gid(gid):
            position = await qb.move(gid, req.pos, req.how)
        else:
            position = await rpc.change_position(gid, req.pos, req.how)
        poller.poke()
        return {"ok": True, "position": position}

    @app.post("/api/download/{gid}/select")
    async def select_files(gid: str, req: SelectFilesRequest):
        if qbt.is_gid(gid):
            await qb.select(gid, req.indices)
            poller.poke()
            return {"ok": True, "select-file": ",".join(str(i) for i in req.indices)}
        # A plain selection replaces any priorities rather than fighting them.
        file_priorities.entries.pop(gid, None)
        value = ",".join(str(i) for i in req.indices) if req.indices else ""
        await rpc.change_option(gid, {"select-file": value})
        poller.poke()
        return {"ok": True, "select-file": value}

    @app.post("/api/download/{gid}/files")
    async def set_file_priorities(gid: str, req: FilePrioritiesRequest):
        try:
            if qbt.is_gid(gid):
                change = await qb.set_levels(gid, req.levels)
            else:
                change = await file_priorities.set(gid, req.levels)
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
        poller.poke()
        return {"ok": True, "changed": change}

    @app.post("/api/download/{gid}/retry")
    async def retry(gid: str):
        detail = await (qb.retry(gid) if qbt.is_gid(gid) else engine._restart(gid))
        poller.poke()
        store.add_event("info", f"Retry {gid}: {detail}", gid=gid)
        return {"ok": True, "detail": detail}

    # ---- global ----------------------------------------------------------
    @app.post("/api/global/pause-all")
    async def pause_all(force: bool = False):
        await rpc.pause_all(force=force)
        await qb.pause_all()
        poller.poke()
        return {"ok": True}

    @app.post("/api/global/resume-all")
    async def resume_all():
        await rpc.unpause_all()
        await qb.resume_all()
        poller.poke()
        return {"ok": True}

    @app.post("/api/global/purge")
    async def purge_all():
        await rpc.purge_results()
        poller.poke()
        return {"ok": True}

    @app.get("/api/global/options")
    async def get_global_options():
        options = await rpc.get_global_option()
        options[seeding.KEY] = "true" if download_only.enabled else "false"
        if download_only.enabled:
            # Live it is held at the floor; show what applies once this is off.
            options["max-overall-upload-limit"] = download_only.configured_upload_limit()
        return options

    @app.post("/api/global/options")
    async def set_global_options(req: OptionsRequest):
        options = clean_options(req.options)
        if not options:
            raise HTTPException(400, "no options given")
        # Not an aria2 option: it must never reach aria2c's command line.
        wanted = options.pop(seeding.KEY, None)
        if wanted is not None and seeding.truthy(wanted) != download_only.enabled:
            await download_only.set(seeding.truthy(wanted))
            await qb.set_download_only()
        if not options:
            poller.poke()
            return {"ok": True, "applied": {seeding.KEY: wanted}, "pending": {}}
        held = download_only.enabled and "max-overall-upload-limit" in options
        live_options = dict(options)
        if held:
            # Saved for when download-only is switched off; the floor stays live.
            live_options.pop("max-overall-upload-limit")
        if live_options:
            await rpc.change_global_option(live_options)
        try:
            await qb.set_global_limits(options)
        except qbt.QBError as exc:
            store.add_event("warn", f"qBittorrent did not take the new limits: {exc}")
        # Mirror into config so a manager/aria2c restart keeps the change.
        persistable = {k: v for k, v in options.items() if not isinstance(v, list)}
        cfg.data["aria2"]["options"].update(persistable)
        cfg._user.setdefault("aria2", {}).setdefault("options", {}).update(persistable)
        cfg.save()

        # aria2 only accepts a subset of its options through changeGlobalOption.
        # For the rest it answers OK and changes nothing, so taking that OK at
        # face value reported success for edits that never happened — the value
        # reappeared unchanged on the next read. Ask aria2 what it actually
        # holds now and split the answer honestly: what is live, and what is
        # only written down and waiting for aria2c to restart.
        try:
            live = await rpc.get_global_option()
        except Exception:  # never fail the write because the read-back failed
            live = {}
        applied, pending = {}, {}
        for key, value in options.items():
            if isinstance(value, list) or not live or (held and key == "max-overall-upload-limit"):
                applied[key] = value
            elif str(live.get(key)) == str(value):
                applied[key] = value
            else:
                pending[key] = value

        if wanted is not None:
            applied[seeding.KEY] = wanted
        note = "Global options updated: " + ", ".join(applied) if applied else ""
        if pending:
            note = (note + "; " if note else "") + (
                "saved for next aria2c start (not changeable while running): "
                + ", ".join(pending)
            )
        store.add_event("info", note)
        poller.poke()
        return {"ok": True, "applied": applied, "pending": pending}

    # ---- rules -----------------------------------------------------------
    @app.get("/api/routing")
    async def get_routing():
        return router.public_state()

    @app.post("/api/routing")
    async def set_routing(req: RoutingRequest):
        router.save(enabled=req.enabled, folders=req.folders, extensions=req.extensions)
        return {"ok": True, **router.public_state()}

    @app.get("/api/rules")
    async def get_rules():
        return {
            "enabled": engine.enabled,
            "speed_source": engine.speed_source(),
            "speed_sources": list(SPEED_SOURCES),
            "rules": cfg.rules,
            "actions": list(ACTIONS),
            "triggers": engine.trigger_log[:100],
            "state": engine.public_state(),
        }

    @app.post("/api/rules")
    async def set_rules(req: RulesRequest):
        if req.enabled is not None:
            cfg.data["rules_enabled"] = bool(req.enabled)
        if req.speed_source is not None:
            choice = req.speed_source.strip().lower()
            if choice not in SPEED_SOURCES:
                raise HTTPException(
                    400, f"speed_source must be one of: {', '.join(SPEED_SOURCES)}"
                )
            cfg.data["rules_speed_source"] = choice
            cfg._user["rules_speed_source"] = choice
        if req.rules is not None:
            problems: list[str] = []
            names: set[str] = set()
            for rule in req.rules:
                for problem in engine.validate(rule):
                    problems.append(f"{rule.get('name', '?')}: {problem}")
                name = str(rule.get("name", ""))
                if name in names:
                    problems.append(f"duplicate rule name {name!r}")
                names.add(name)
            if problems:
                raise HTTPException(400, "; ".join(problems))
            cfg.rules = req.rules
        cfg.save()
        store.add_event("info", "Rules updated")
        return {
            "ok": True,
            "enabled": engine.enabled,
            "speed_source": engine.speed_source(),
            "rules": cfg.rules,
        }

    @app.post("/api/rules/{name}/toggle")
    async def toggle_rule(name: str, enabled: bool | None = Body(default=None, embed=True)):
        rules = cfg.rules
        for rule in rules:
            if rule.get("name") == name:
                rule["enabled"] = (not rule.get("enabled", True)) if enabled is None else bool(enabled)
                cfg.rules = rules
                cfg.save()
                store.add_event(
                    "info", f"Rule {name} {'enabled' if rule['enabled'] else 'disabled'}"
                )
                return {"ok": True, "rule": rule}
        raise HTTPException(404, f"no rule named {name!r}")

    # ---- finished-download history --------------------------------------
    @app.get("/api/history")
    async def history_list(limit: int = 200, status: str | None = None):
        return {"summary": history.summary(), "entries": history.list(limit, status)}

    @app.post("/api/history/readd")
    async def history_readd(req: HistoryKeyRequest):
        """Queue a past download again from its recorded URL."""
        entry = history.get(req.key)
        if not entry:
            raise HTTPException(404, "no such history entry")
        url = entry.get("url")
        if not url:
            raise HTTPException(
                409, "no URL was recorded for this entry (torrent or metadata download)"
            )
        options = {}
        if entry.get("dir"):
            options["dir"] = entry["dir"]
        if qbt.is_magnet(url) and qb.ready:
            gid = await qb.add_magnet(url, clean_options(options))
            poller.poke()
            store.add_event("info", f"Re-added from history: {entry.get('name') or url}")
            return {"ok": True, "gid": gid}
        if entry.get("name"):
            options["out"] = os.path.basename(entry["name"])
        gid = await rpc.add_uri([url], clean_options(options))
        poller.poke()
        store.add_event("info", f"Re-added from history: {entry.get('name') or url}")
        return {"ok": True, "gid": gid}

    @app.post("/api/history/remove")
    async def history_remove(req: HistoryKeyRequest):
        if not history.remove(req.key):
            raise HTTPException(404, "no such history entry")
        return {"ok": True}

    @app.post("/api/history-clear")
    async def history_clear(purge_aria2: bool = True):
        """Clear the record *and* aria2's own finished results.

        Clearing only our own file left every finished download still listed,
        because aria2 keeps its results until they are purged or it restarts —
        which read as "clear did nothing".
        """
        removed = history.clear()
        purged = False
        if purge_aria2:
            try:
                await rpc.purge_results()
                purged = True
            except (Aria2Error, aiohttp.ClientError):
                pass
        poller.poke()
        store.add_event(
            "info",
            f"History cleared ({removed} record(s))"
            + (" and aria2's finished results purged" if purged else ""),
        )
        return {"ok": True, "removed": removed, "purgedAria2Results": purged}

    # ---- browser intake ---------------------------------------------------
    @app.get("/api/intake/ping")
    async def intake_ping():
        return {
            "ok": True,
            "name": "Aria Download Manager",
            "version": VERSION,
            "aria2": supervisor.status().get("running", False),
            "torrentEngine": qbt.ENGINE if qb.ready else "aria2",
            "defaultDir": cfg.get("aria2.options.dir"),
            "socket": ipc.path,
        }

    @app.post("/api/intake/add")
    async def intake_add(req: IntakeRequest):
        uris = split_uris(req.urls, req.url)
        if not uris:
            raise HTTPException(400, "no url given")

        options = clean_options(req.options)
        headers: list[str] = list(options.pop("header", []) or []) if isinstance(
            options.get("header"), list
        ) else ([options.pop("header")] if options.get("header") else [])
        if isinstance(req.headers, dict):
            headers.extend(f"{k}: {v}" for k, v in req.headers.items() if k and v)
        else:
            headers.extend(str(h) for h in req.headers if str(h).strip())
        if req.cookie:
            headers.append(f"Cookie: {req.cookie}")
        if headers:
            options["header"] = headers
        if req.referer:
            options["referer"] = req.referer
        if req.userAgent:
            options["user-agent"] = req.userAgent
        if req.dir:
            options["dir"] = str(req.dir)
        if req.filename:
            # 'out' must stay a bare filename; a path here would escape dir.
            options["out"] = os.path.basename(req.filename.strip()) or req.filename.strip()
        if req.paused:
            options["pause"] = "true"

        fetch_headers: dict[str, str] = {}
        for line in headers:
            name, _, value = str(line).partition(":")
            if name.strip() and value.strip():
                fetch_headers[name.strip()] = value.strip()
        if req.referer:
            fetch_headers["Referer"] = req.referer
        if req.userAgent:
            fetch_headers["User-Agent"] = req.userAgent
        torrent_options = {k: v for k, v in options.items()
                           if k in ("dir", "pause", "download-only")}
        # A browser download is often named only by its Content-Disposition.
        named_torrent = (req.filename or "").strip().lower().endswith(".torrent")
        qb_gids, rest = await _add_to_qb(uris, torrent_options, req.paused, fetch_headers,
                                         maybe_torrent=named_torrent)
        gids = qb_gids + [await rpc.add_uri([uri], dict(options), None) for uri in rest]
        poller.poke()
        origin = req.source or "browser"
        store.add_event(
            "info",
            f"Browser queued {os.path.basename(uris[0].split('?')[0]) or uris[0]}"
            + (f" (+{len(uris) - 1} more)" if len(uris) > 1 else ""),
            gids=gids,
            source=origin,
        )
        return {"ok": True, "gids": gids, "count": len(gids)}

    return app
