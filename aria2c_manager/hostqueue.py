"""Sequential hoster queue.

Holds *page* URLs (mediafire.com/file/…, kenfiles.com/…), resolves each to a
direct link only when its turn comes, hands it to aria2, waits for that download
to finish, then starts the next one. One download at a time by default, which is
what these hosts want anyway — most refuse parallel free downloads.

Job lifecycle:

    queued ──resolve──> downloading ──aria2 finishes──> complete
      │                     │
      │                     └──aria2 error────────────> failed
      ├──needs a human────> needs_input ──answer──> downloading
      └──resolve error────> queued (retry, backoff) or failed
"""

from __future__ import annotations

import asyncio
import itertools
import json
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import aiohttp
from yarl import URL

from .config import Config, expand
from .hosters import (
    DEFAULT_UA,
    Interaction,
    Resolved,
    ResolveError,
    build_registry,
    describe,
    pick_resolver,
)
from .hosters.base import host_of
from .rpc import Aria2Error, Aria2RPC
from .state import Store

ACTIVE_STATES = ("resolving", "downloading")
DONE_STATES = ("complete", "failed", "cancelled")


@dataclass
class Job:
    id: str
    page_url: str
    state: str = "queued"
    resolver: str = ""
    direct_url: str = ""
    filename: str = ""
    size: int | None = None
    gid: str = ""
    note: str = ""
    error: str = ""
    attempts: int = 0
    added_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    started_at: float = 0.0
    finished_at: float = 0.0
    next_attempt_at: float = 0.0
    options: dict[str, Any] = field(default_factory=dict)
    interaction: dict[str, Any] | None = None

    def touch(self, state: str | None = None) -> None:
        if state:
            self.state = state
        self.updated_at = time.time()

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "Job":
        known = {k: v for k, v in data.items() if k in cls.__dataclass_fields__}
        known.setdefault("id", uuid.uuid4().hex[:12])
        return cls(**known)


class HosterQueue:
    def __init__(self, cfg: Config, rpc: Aria2RPC, store: Store, on_change=None):
        self.cfg = cfg
        self.rpc = rpc
        self.store = store
        self.on_change = on_change or (lambda: None)
        self.jobs: list[Job] = []
        self.resolvers = build_registry(cfg)
        self.paused = False
        self.last_error = ""
        #: host -> {"cookies": {...}, "user_agent": str, "updated_at": ts}
        #: Shared from the browser so a Cloudflare-cleared session can be reused.
        self.creds: dict[str, dict] = {}
        self._task: asyncio.Task | None = None
        self._ids = itertools.count(1)
        self._dirty = False
        self.load()
        self.load_credentials()

    # ---- config ----------------------------------------------------------
    @property
    def enabled(self) -> bool:
        return bool(self.cfg.get("hosters.enabled", True))

    @property
    def max_active(self) -> int:
        return max(1, int(self.cfg.get("hosters.max_active", 1) or 1))

    @property
    def wait_cap(self) -> float:
        return float(self.cfg.get("hosters.wait_cap_seconds", 120) or 120)

    @property
    def user_agent(self) -> str:
        return str(self.cfg.get("hosters.user_agent") or DEFAULT_UA)

    @property
    def creds_path(self) -> Path:
        return self.state_path.with_name("hoster-cookies.json")

    @property
    def state_path(self) -> Path:
        return expand(
            self.cfg.get("hosters.state_file")
            or "~/.local/share/aria2c-manager/hosters.json"
        )

    # ---- persistence -----------------------------------------------------
    def load(self) -> None:
        path = self.state_path
        if not path.is_file():
            return
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        self.jobs = []
        for raw in data.get("jobs", []):
            job = Job.from_dict(raw)
            # A restart invalidates any half-finished resolution.
            if job.state == "resolving":
                job.touch("queued")
            self.jobs.append(job)
        self.paused = bool(data.get("paused", False))

    def save(self) -> None:
        path = self.state_path
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            payload = {"paused": self.paused, "jobs": [job.to_dict() for job in self.jobs]}
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(payload, indent=1), encoding="utf-8")
            tmp.replace(path)
        except OSError as exc:
            self.last_error = f"could not save hoster queue: {exc}"

    # ---- browser-shared credentials -------------------------------------
    def load_credentials(self) -> None:
        path = self.creds_path
        if not path.is_file():
            return
        try:
            self.creds = json.loads(path.read_text(encoding="utf-8")) or {}
        except (OSError, json.JSONDecodeError):
            self.creds = {}

    def save_credentials(self) -> None:
        path = self.creds_path
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.creds, indent=1), encoding="utf-8")
            tmp.chmod(0o600)  # session cookies: keep them to this user
            tmp.replace(path)
        except OSError as exc:
            self.last_error = f"could not save hoster cookies: {exc}"

    def set_credentials(
        self, domain: str, cookies: dict | str, user_agent: str = ""
    ) -> dict:
        """Store cookies (and the matching UA) the browser shared for a host.

        Cloudflare binds a cf_clearance cookie to the user agent that earned it, so
        the UA must travel with the cookies or the clearance is worthless.
        """
        domain = host_of(f"http://{domain}") or str(domain).strip().lower()
        if not domain:
            raise ValueError("no domain given")
        if isinstance(cookies, str):
            parsed: dict[str, str] = {}
            for part in cookies.split(";"):
                name, _, value = part.strip().partition("=")
                if name and value:
                    parsed[name.strip()] = value.strip()
            cookies = parsed
        cookies = {str(k): str(v) for k, v in (cookies or {}).items() if k}
        if not cookies:
            raise ValueError("no cookies given")
        self.creds[domain] = {
            "cookies": cookies,
            "user_agent": user_agent or self.user_agent,
            "updated_at": time.time(),
        }
        self.save_credentials()
        self.store.add_event(
            "info",
            f"Hoster: stored {len(cookies)} cookie(s) for {domain}"
            + (" (includes Cloudflare clearance)" if "cf_clearance" in cookies else ""),
        )
        # A job parked on a Cloudflare wall can be worth another try now.
        requeued = 0
        for job in self.jobs:
            if job.state == "needs_input" and host_of(job.page_url) == domain \
                    and ((job.interaction or {}).get("state") or {}).get("cloudflare"):
                job.attempts = 0
                job.error = ""
                job.interaction = None
                job.touch("queued")
                requeued += 1
        if requeued:
            self.store.add_event("info", f"Hoster: retrying {requeued} job(s) for {domain}")
        self._changed()
        return {"domain": domain, "cookies": len(cookies), "requeued": requeued}

    def credential_summary(self) -> list[dict]:
        """What we hold, without ever revealing the values."""
        return [
            {
                "domain": domain,
                "cookies": len(data.get("cookies") or {}),
                "names": sorted((data.get("cookies") or {}).keys()),
                "has_cloudflare_clearance": "cf_clearance" in (data.get("cookies") or {}),
                "user_agent": data.get("user_agent", ""),
                "updated_at": data.get("updated_at", 0),
            }
            for domain, data in sorted(self.creds.items())
        ]

    def _changed(self) -> None:
        self._dirty = True
        self.on_change()

    # ---- queue operations ------------------------------------------------
    def add(self, urls: list[str], options: dict | None = None, position: int | None = None) -> list[Job]:
        created: list[Job] = []
        for url in urls:
            url = url.strip()
            if not url:
                continue
            resolver = pick_resolver(url, self.resolvers)
            job = Job(
                id=uuid.uuid4().hex[:12],
                page_url=url,
                resolver=resolver.name if resolver else "",
                options=dict(options or {}),
            )
            created.append(job)
        if position is None:
            self.jobs.extend(created)
        else:
            index = max(0, min(int(position), len(self.jobs)))
            self.jobs[index:index] = created
        if created:
            self.store.add_event(
                "info",
                f"Hoster queue: added {len(created)} link(s)"
                + (f" ({created[0].resolver})" if len(created) == 1 else ""),
            )
            self._changed()
        return created

    def get(self, job_id: str) -> Job | None:
        return next((job for job in self.jobs if job.id == job_id), None)

    def remove(self, job_id: str) -> bool:
        job = self.get(job_id)
        if not job:
            return False
        if job.state == "downloading" and job.gid:
            asyncio.create_task(self._silent_remove_gid(job.gid))
        self.jobs = [j for j in self.jobs if j.id != job_id]
        self._changed()
        return True

    def cancel(self, job_id: str) -> bool:
        job = self.get(job_id)
        if not job or job.state in DONE_STATES:
            return False
        if job.state == "downloading" and job.gid:
            asyncio.create_task(self._silent_remove_gid(job.gid))
        job.error = "cancelled"
        job.finished_at = time.time()
        job.touch("cancelled")
        self._changed()
        return True

    def retry(self, job_id: str) -> bool:
        job = self.get(job_id)
        if not job:
            return False
        job.attempts = 0
        job.error = ""
        job.gid = ""
        job.direct_url = ""
        job.interaction = None
        job.next_attempt_at = 0.0
        job.finished_at = 0.0
        job.touch("queued")
        self._changed()
        return True

    def reorder(self, ids: list[str]) -> None:
        order = {job_id: index for index, job_id in enumerate(ids)}
        self.jobs.sort(key=lambda job: order.get(job.id, len(order)))
        self._changed()

    def clear_finished(self) -> int:
        before = len(self.jobs)
        self.jobs = [job for job in self.jobs if job.state not in DONE_STATES]
        removed = before - len(self.jobs)
        if removed:
            self._changed()
        return removed

    def set_paused(self, paused: bool) -> None:
        self.paused = bool(paused)
        self.store.add_event("info", f"Hoster queue {'paused' if paused else 'resumed'}")
        self._changed()

    async def _silent_remove_gid(self, gid: str) -> None:
        for force in (True, False):
            try:
                await self.rpc.remove(gid, force=force)
                break
            except (Aria2Error, aiohttp.ClientError):
                continue
        try:
            await self.rpc.remove_result(gid)
        except (Aria2Error, aiohttp.ClientError):
            pass

    # ---- the userscript hand-back ---------------------------------------
    def match_by_page(self, page_url: str) -> Job | None:
        """Find a job waiting on a human for this page (referer match)."""
        if not page_url:
            return None
        target = _normalize(page_url)
        target_host = host_of(page_url)
        for job in self.jobs:
            if job.state != "needs_input":
                continue
            candidate = _normalize(job.page_url)
            if candidate == target or candidate.startswith(target) or target.startswith(candidate):
                return job
            interaction_page = ((job.interaction or {}).get("page_url") or "")
            if interaction_page and _normalize(interaction_page) == target:
                return job
            # Fall back to host-level matching: these flows bounce across paths.
            if target_host and host_of(job.page_url) == target_host:
                return job
        return None

    # ---- answering an interaction ---------------------------------------
    async def answer(self, job_id: str, reply: dict) -> Job:
        job = self.get(job_id)
        if not job:
            raise KeyError(job_id)
        if job.state != "needs_input":
            raise ValueError(f"job {job_id} is not waiting for input (state={job.state})")

        interaction = Interaction(**{
            key: value for key, value in (job.interaction or {}).items()
            if key in Interaction.__dataclass_fields__
        })
        resolver = pick_resolver(job.page_url, self.resolvers)
        if resolver is None:
            raise ValueError("no resolver for this job")

        job.touch("resolving")
        self._changed()
        try:
            async with self._http(job.page_url) as session:
                outcome = await resolver.answer(
                    session, interaction, reply, wait_cap=self.wait_cap
                )
            await self._apply_outcome(job, outcome)
        except (ResolveError, aiohttp.ClientError, ValueError) as exc:
            job.error = str(exc)
            job.touch("needs_input")  # let the user try again
            self.store.add_event("error", f"Hoster: {job.page_url} — {exc}")
            self._changed()
        return job

    # ---- worker ----------------------------------------------------------
    def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._run())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
        if self._dirty:
            self.save()

    def _http(self, page_url: str) -> aiohttp.ClientSession:
        """A fresh session carrying whatever the browser shared for this host."""
        domain = host_of(page_url)
        creds = self.creds.get(domain) or {}
        user_agent = creds.get("user_agent") or self.user_agent
        session = aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=180),
            headers={"User-Agent": user_agent},
            cookie_jar=aiohttp.CookieJar(unsafe=True),
        )
        if cookies := creds.get("cookies"):
            for scheme in ("https", "http"):
                session.cookie_jar.update_cookies(cookies, response_url=URL(f"{scheme}://{domain}"))
        return session

    async def _run(self) -> None:
        interval = float(self.cfg.get("hosters.poll_interval", 1.0) or 1.0)
        while True:
            try:
                await self._tick()
                if self._dirty:
                    self.save()
                    self._dirty = False
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.last_error = str(exc)
                self.store.add_event("error", f"Hoster queue error: {exc}")
            await asyncio.sleep(interval)

    async def _tick(self) -> None:
        if not self.enabled:
            return
        await self._check_downloads()
        if self.paused:
            return
        active = [job for job in self.jobs if job.state in ACTIVE_STATES]
        if len(active) >= self.max_active:
            return
        now = time.time()
        for job in self.jobs:
            if job.state != "queued" or job.next_attempt_at > now:
                continue
            await self._start_job(job)
            break

    async def _check_downloads(self) -> None:
        """Advance jobs whose aria2 download has finished."""
        for job in [j for j in self.jobs if j.state == "downloading" and j.gid]:
            try:
                status = await self.rpc.tell_status(
                    job.gid, ["status", "completedLength", "totalLength", "errorMessage", "files"]
                )
            except Aria2Error:
                # The result was purged from aria2; treat it as finished.
                job.note = "aria2 result purged before it was seen finishing"
                job.finished_at = time.time()
                job.touch("complete")
                self.store.add_event("info", f"Hoster: {job.filename or job.page_url} finished")
                self._changed()
                continue
            except aiohttp.ClientError:
                return  # aria2 unreachable; try again next tick

            state = status.get("status")
            if state == "complete":
                job.finished_at = time.time()
                job.note = "downloaded"
                job.touch("complete")
                self.store.add_event(
                    "info", f"Hoster: finished {job.filename or job.page_url}"
                )
                self._changed()
            elif state in ("error", "removed"):
                job.error = status.get("errorMessage") or f"aria2 reported {state}"
                job.attempts += 1
                max_attempts = int(self.cfg.get("hosters.max_attempts", 3) or 3)
                if job.attempts >= max_attempts:
                    job.finished_at = time.time()
                    job.touch("failed")
                else:
                    # The direct link may simply have expired — resolve again.
                    job.gid = ""
                    job.direct_url = ""
                    job.next_attempt_at = time.time() + float(
                        self.cfg.get("hosters.retry_backoff_seconds", 30) or 30
                    )
                    job.touch("queued")
                self.store.add_event(
                    "error", f"Hoster: {job.filename or job.page_url} — {job.error}"
                )
                self._changed()

    async def _start_job(self, job: Job) -> None:
        resolver = pick_resolver(job.page_url, self.resolvers)
        if resolver is None:
            job.error = "no resolver matches this URL"
            job.touch("failed")
            self._changed()
            return

        job.resolver = resolver.name
        job.attempts += 1
        job.error = ""
        job.started_at = job.started_at or time.time()
        job.touch("resolving")
        self.store.add_event("info", f"Hoster: resolving {job.page_url} ({resolver.name})")
        self._changed()

        try:
            async with self._http(job.page_url) as session:
                outcome = await resolver.resolve(session, job.page_url, wait_cap=self.wait_cap)
            await self._apply_outcome(job, outcome)
        except ResolveError as exc:
            self._fail_or_retry(job, str(exc), permanent=exc.permanent)
        except asyncio.TimeoutError:
            self._fail_or_retry(job, "timed out talking to the host")
        except aiohttp.ClientError as exc:
            self._fail_or_retry(job, f"network error: {exc}")

    async def _apply_outcome(self, job: Job, outcome: Resolved | Interaction) -> None:
        if isinstance(outcome, Interaction):
            # The host usually names the file on the wait page; show it while the
            # job sits parked rather than a URL slug.
            if fname := (outcome.state or {}).get("fname"):
                job.filename = job.filename or fname
            job.interaction = {
                "kind": outcome.kind,
                "message": outcome.message,
                "page_url": outcome.page_url,
                "image_url": outcome.image_url,
                "wait_seconds": outcome.wait_seconds,
                "state": outcome.state,
            }
            job.touch("needs_input")
            self.store.add_event(
                "warn",
                f"Hoster: {job.page_url} needs you — {outcome.message}",
            )
            self._changed()
            return

        options = outcome.aria2_options(self.user_agent)
        options.update({k: v for k, v in (job.options or {}).items() if v})
        if not options.get("dir") and self.cfg.get("hosters.dir"):
            options["dir"] = str(expand(self.cfg.get("hosters.dir")))

        try:
            gid = await self.rpc.add_uri([outcome.url], options)
        except (Aria2Error, aiohttp.ClientError) as exc:
            self._fail_or_retry(job, f"aria2 refused the link: {exc}")
            return

        job.gid = gid
        job.direct_url = outcome.url
        job.filename = outcome.filename or job.filename
        job.size = outcome.size or job.size
        job.note = outcome.note
        job.interaction = None
        job.error = ""
        job.touch("downloading")
        self.store.add_event(
            "info", f"Hoster: downloading {job.filename or outcome.url[:60]} (gid {gid})"
        )
        self._changed()

    def _fail_or_retry(self, job: Job, message: str, permanent: bool = False) -> None:
        job.error = message
        max_attempts = int(self.cfg.get("hosters.max_attempts", 3) or 3)
        if permanent or job.attempts >= max_attempts:
            job.finished_at = time.time()
            job.touch("failed")
            self.store.add_event("error", f"Hoster: gave up on {job.page_url} — {message}")
        else:
            job.next_attempt_at = time.time() + float(
                self.cfg.get("hosters.retry_backoff_seconds", 30) or 30
            )
            job.touch("queued")
            self.store.add_event(
                "warn",
                f"Hoster: {job.page_url} — {message} "
                f"(attempt {job.attempts}, retrying)",
            )
        self._changed()

    # ---- exposure --------------------------------------------------------
    def public(self) -> dict:
        counts: dict[str, int] = {}
        jobs: list[dict] = []
        for job in self.jobs:
            counts[job.state] = counts.get(job.state, 0) + 1
            data = job.to_dict()
            if data.get("interaction"):
                # Never ship the internal form fields and session cookies to the
                # browser; the UI only needs to know what to ask for.
                interaction = dict(data["interaction"])
                interaction.pop("state", None)
                data["interaction"] = interaction
            jobs.append(data)
        return {
            "enabled": self.enabled,
            "paused": self.paused,
            "max_active": self.max_active,
            "wait_cap_seconds": self.wait_cap,
            "counts": counts,
            "jobs": jobs,
            "resolvers": describe(self.resolvers),
            "credentials": self.credential_summary(),
            "last_error": self.last_error,
        }


def _normalize(url: str) -> str:
    """Compare URLs ignoring scheme, www, query, fragment and trailing bits."""
    url = (url or "").split("#")[0].split("?")[0]
    url = url.split("://", 1)[-1]
    if url.startswith("www."):
        url = url[4:]
    return url.rstrip("/").removesuffix("/file").rstrip("/").lower()
