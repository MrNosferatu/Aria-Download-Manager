"""FastAPI application: REST commands, SSE state stream, browser intake."""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import os
import signal
from contextlib import asynccontextmanager
from typing import Any

import aiohttp
from fastapi import Body, FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import files as filetools
from .config import STATIC_DIR, Config, stringify
from .history import History
from .rpc import DETAIL_KEYS, Aria2Error, Aria2RPC
from .rules import ACTIONS, SPEED_SOURCES, RuleEngine
from .state import Poller, Store
from .supervisor import Aria2Supervisor

VERSION = "1.0.0"

FAVICON_SVG = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">'
    '<rect width="32" height="32" rx="7" fill="#161a21"/>'
    '<path d="M16 5v13m0 0l-6-6m6 6l6-6" stroke="#4c8dff" stroke-width="3.2" '
    'fill="none" stroke-linecap="round" stroke-linejoin="round"/>'
    '<rect x="8" y="23" width="16" height="3.2" rx="1.6" fill="#4c8dff"/>'
    "</svg>"
)


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


class ManagerConfigRequest(BaseModel):
    """The handful of manager settings a UI may change.

    Deliberately not a free-form config writer: everything else in config.yaml
    is either machine-specific or unsafe to change from an unauthenticated
    loopback API.
    """

    web_ui: bool | None = None
    poll_interval: float | None = None
    poll_interval_idle: float | None = None


class RulesRequest(BaseModel):
    rules: list[dict[str, Any]] | None = None
    enabled: bool | None = None
    #: aria2 | measured | hybrid — which speed figure rules judge by.
    speed_source: str | None = None


class SelectFilesRequest(BaseModel):
    indices: list[int]


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


def sse_frame(message: dict) -> str:
    return f"event: {message.get('type', 'message')}\ndata: {json.dumps(message.get('data'))}\n\n"


def decode_b64(data: str, what: str) -> str:
    payload = data.split(",", 1)[1] if data.startswith("data:") else data
    payload = payload.strip()
    try:
        base64.b64decode(payload, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(400, f"{what} is not valid base64: {exc}") from exc
    return payload


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
    history = History(cfg)
    poller.observers.append(history.observe)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await rpc.start()
        store.add_event("info", f"aria2c-manager {VERSION} starting")
        try:
            await supervisor.start()
        except Exception as exc:
            supervisor.last_error = str(exc)
            store.add_event("error", f"aria2c unavailable: {exc}")
        poller.start()
        try:
            yield
        finally:
            store.publish({"type": "shutdown", "data": {"ok": True}})
            history.save(force=True)
            await poller.stop()
            await supervisor.stop()
            await rpc.close()

    app = FastAPI(title="aria2c-manager", version=VERSION, lifespan=lifespan)
    # Open CORS on purpose: the extension posts from arbitrary page origins and
    # the server is bound to loopback with no credentials of its own.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    app.state.cfg = cfg
    app.state.rpc = rpc
    app.state.store = store
    app.state.supervisor = supervisor
    app.state.engine = engine
    app.state.poller = poller
    app.state.history = history

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
    @app.get("/api/ping")
    async def ping():
        return {"ok": True, "name": "aria2c-manager", "version": VERSION}

    @app.get("/api/state")
    async def get_state():
        return store.snapshot

    @app.get("/api/config")
    async def get_config():
        return cfg.public()

    @app.post("/api/config")
    async def set_config(req: ManagerConfigRequest):
        changed: dict[str, Any] = {}
        # `save()` writes the user's own file back, so every change has to land
        # in both the live config and that copy.
        if req.web_ui is not None:
            cfg.data["server"]["web_ui"] = bool(req.web_ui)
            cfg._user.setdefault("server", {})["web_ui"] = bool(req.web_ui)
            changed["server.web_ui"] = bool(req.web_ui)
        if req.poll_interval is not None:
            value = max(0.25, float(req.poll_interval))
            cfg.data["poll_interval"] = value
            cfg._user["poll_interval"] = value
            poller.interval = value
            changed["poll_interval"] = value
        if req.poll_interval_idle is not None:
            value = max(poller.interval, float(req.poll_interval_idle))
            cfg.data["poll_interval_idle"] = value
            cfg._user["poll_interval_idle"] = value
            poller.idle_interval = value
            changed["poll_interval_idle"] = value
        if not changed:
            raise HTTPException(400, "nothing to change")
        cfg.save()
        store.add_event("info", "Config updated: " + ", ".join(sorted(changed)))
        # Mounting/unmounting the static UI can only happen at startup, so say
        # so rather than pretending the toggle took effect.
        return {
            "ok": True,
            "changed": changed,
            "restartRequired": "server.web_ui" in changed,
            "config": cfg.public(),
        }

    @app.post("/api/restart")
    async def restart_manager():
        """Exit so the service manager brings us back with the new config."""

        async def bye():
            await asyncio.sleep(0.2)
            os.kill(os.getpid(), signal.SIGTERM)

        asyncio.create_task(bye())
        return {"ok": True, "restarting": True}

    @app.get("/api/aria2/status")
    async def aria2_status():
        return supervisor.status()

    @app.post("/api/aria2/restart")
    async def aria2_restart():
        await supervisor.restart()
        poller.poke()
        return {"ok": True, "status": supervisor.status()}

    @app.get("/api/log")
    async def get_log(limit: int = 200):
        return {"events": store.event_list(limit), "triggers": engine.trigger_log[:100]}

    # ---- live stream -----------------------------------------------------
    @app.get("/api/events")
    async def events(request: Request):
        queue = store.subscribe()

        async def generator():
            try:
                yield sse_frame({"type": "state", "data": store.snapshot})
                yield sse_frame({"type": "backlog", "data": store.event_list(60)})
                while True:
                    if await request.is_disconnected():
                        return
                    try:
                        message = await asyncio.wait_for(queue.get(), timeout=15)
                    except asyncio.TimeoutError:
                        yield ": keepalive\n\n"
                        continue
                    if message.get("type") == "shutdown":
                        # The manager is going down; end the response instead of
                        # holding the shutdown open. Clients reconnect on their own.
                        yield sse_frame(message)
                        return
                    yield sse_frame(message)
            finally:
                store.unsubscribe(queue)

        return StreamingResponse(
            generator(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    # ---- adding ----------------------------------------------------------
    async def _add_uris(req: AddRequest) -> dict:
        uris = split_uris(req.uris, req.url)
        if not uris:
            raise HTTPException(400, "no URI given")
        options = clean_options(req.options)
        if req.paused:
            options["pause"] = "true"
        gids: list[str] = []
        if req.mirrors:
            gids.append(await rpc.add_uri(uris, options, req.position))
        else:
            for index, uri in enumerate(uris):
                position = None if req.position is None else req.position + index
                gids.append(await rpc.add_uri([uri], dict(options), position))
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
        else:
            gids = [await rpc.add_torrent(payload, req.uris, options, req.position)]
        poller.poke()
        store.add_event("info", f"Added {req.kind} {req.filename or ''}".strip(), gids=gids)
        return {"ok": True, "gids": gids}

    # ---- per-download ----------------------------------------------------
    @app.get("/api/download/{gid}")
    async def download_detail(gid: str):
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
        return {
            "status": status,
            "files": files or [],
            "uris": uris or [],
            "options": options or {},
            "servers": servers or [],
            "peers": (peers or [])[:60],
            "pieceMap": piece_map(
                status.get("bitfield", ""), int(status.get("numPieces") or 0)
            ),
        }

    @app.post("/api/download/{gid}/pause")
    async def pause(gid: str, force: bool = False):
        await rpc.pause(gid, force=force)
        poller.poke()
        return {"ok": True}

    @app.post("/api/download/{gid}/resume")
    async def resume(gid: str):
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
                if req.action == "pause":
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
            except Aria2Error as exc:
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
        if not options:
            raise HTTPException(400, "no options given")
        await rpc.change_option(gid, options)
        poller.poke()
        return {"ok": True, "applied": options}

    @app.post("/api/download/{gid}/position")
    async def set_position(gid: str, req: PositionRequest):
        if req.how not in ("POS_SET", "POS_CUR", "POS_END"):
            raise HTTPException(400, "how must be POS_SET, POS_CUR or POS_END")
        position = await rpc.change_position(gid, req.pos, req.how)
        poller.poke()
        return {"ok": True, "position": position}

    @app.post("/api/download/{gid}/select")
    async def select_files(gid: str, req: SelectFilesRequest):
        value = ",".join(str(i) for i in req.indices) if req.indices else ""
        await rpc.change_option(gid, {"select-file": value})
        poller.poke()
        return {"ok": True, "select-file": value}

    @app.post("/api/download/{gid}/retry")
    async def retry(gid: str):
        detail = await engine._restart(gid)
        poller.poke()
        store.add_event("info", f"Retry {gid}: {detail}", gid=gid)
        return {"ok": True, "detail": detail}

    # ---- global ----------------------------------------------------------
    @app.post("/api/global/pause-all")
    async def pause_all(force: bool = False):
        await rpc.pause_all(force=force)
        poller.poke()
        return {"ok": True}

    @app.post("/api/global/resume-all")
    async def resume_all():
        await rpc.unpause_all()
        poller.poke()
        return {"ok": True}

    @app.post("/api/global/purge")
    async def purge_all():
        await rpc.purge_results()
        poller.poke()
        return {"ok": True}

    @app.post("/api/global/save-session")
    async def save_session():
        await rpc.save_session()
        return {"ok": True}

    @app.get("/api/global/options")
    async def get_global_options():
        return await rpc.get_global_option()

    @app.post("/api/global/options")
    async def set_global_options(req: OptionsRequest):
        options = clean_options(req.options)
        if not options:
            raise HTTPException(400, "no options given")
        await rpc.change_global_option(options)
        # Mirror into config so a manager/aria2c restart keeps the change.
        persistable = {k: v for k, v in options.items() if not isinstance(v, list)}
        cfg.data["aria2"]["options"].update(persistable)
        cfg._user.setdefault("aria2", {}).setdefault("options", {}).update(persistable)
        cfg.save()
        store.add_event("info", "Global options updated: " + ", ".join(options))
        poller.poke()
        return {"ok": True, "applied": options}

    # ---- rules -----------------------------------------------------------
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
    # /api/userscript/* is the pre-extension name for these two, kept so
    # anything already posting there keeps working.
    @app.get("/api/intake/ping")
    @app.get("/api/userscript/ping")
    async def intake_ping():
        return {
            "ok": True,
            "name": "aria2c-manager",
            "version": VERSION,
            "aria2": supervisor.status().get("running", False),
            "defaultDir": cfg.get("aria2.options.dir"),
        }

    @app.post("/api/intake/add")
    @app.post("/api/userscript/add")
    async def intake_add(req: IntakeRequest, request: Request):
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

        gids = [await rpc.add_uri([uri], dict(options), None) for uri in uris]
        poller.poke()
        origin = request.headers.get("origin") or req.source or "browser"
        store.add_event(
            "info",
            f"Browser queued {os.path.basename(uris[0].split('?')[0]) or uris[0]}"
            + (f" (+{len(uris) - 1} more)" if len(uris) > 1 else ""),
            gids=gids,
            source=origin,
        )
        return {"ok": True, "gids": gids, "count": len(gids)}

    # ---- static UI -------------------------------------------------------
    # Off by default: with the DankMaterialShell widget or the browser extension
    # driving it, the browser UI is optional. The REST/SSE API is unaffected.
    web_ui = bool(cfg.get("server.web_ui", False))
    if web_ui and STATIC_DIR.is_dir():
        app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

        @app.get("/")
        async def index():
            return FileResponse(str(STATIC_DIR / "index.html"))

        @app.get("/favicon.ico")
        async def favicon():
            # Must carry a real body: a 204 here would send bytes with no
            # Content-Length, which h11 rejects ("Too much data for declared
            # Content-Length") on every browser favicon request.
            logo = STATIC_DIR / "aria2-logo.png"
            if logo.is_file():
                return FileResponse(str(logo), media_type="image/png")
            return Response(content=FAVICON_SVG, media_type="image/svg+xml")
    else:

        @app.get("/")
        async def index_disabled():
            return {
                "ok": True,
                "name": "aria2c-manager",
                "version": VERSION,
                "webUi": False,
                "hint": "The web UI is off. Set server.web_ui: true in "
                        f"{cfg.path}, or start with --web-ui. The API is unaffected.",
            }

    return app
