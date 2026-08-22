"""Downloading a segmented stream, and putting it back together.

A progressive file goes to aria2 like anything else — that path does not live
here. This module is for the case aria2 cannot handle: HLS and DASH, where the
"file" is a manifest naming hundreds of segments, and where the video and audio
a site serves are usually two separate streams that have to be muxed back into
one container.

ffmpeg does the fetching and the muxing. It already understands both manifest
formats, follows the segment lists, and can remux without re-encoding, so a
download costs no more CPU than copying bytes. Trying to fetch segments by hand
and concatenate them would mean reimplementing discontinuity handling, init
segments, byte-range playlists and encryption — all of which ffmpeg has already
got right.

Jobs are reported through the poller's snapshot, so both front-ends see them
alongside ordinary downloads without either having to poll something new.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import shutil
import time
import uuid
from pathlib import Path
from typing import Any

#: Terminal states. Anything else is still going.
FINAL = {"complete", "error", "cancelled"}


def _ffmpeg_headers(headers: dict[str, str]) -> str:
    """ffmpeg takes extra request headers as one CRLF-joined blob."""
    lines = [f"{name}: {value}" for name, value in headers.items()
             if value and name.lower() != "user-agent"]
    return "\r\n".join(lines) + "\r\n" if lines else ""


class MediaJob:
    def __init__(self, job_id: str, name: str, path: Path, variant: dict):
        self.id = job_id
        self.name = name
        self.path = path
        self.variant = variant
        self.status = "queued"
        self.progress = 0.0
        self.completed = 0
        self.duration: float | None = None
        self.out_time = 0.0
        self.speed = ""
        self.error = ""
        self.started_at = time.time()
        self.finished_at: float | None = None
        self.proc: asyncio.subprocess.Process | None = None

    @property
    def eta(self) -> int | None:
        if self.status != "running" or not self.duration or self.out_time <= 0:
            return None
        try:
            rate = float(self.speed.rstrip("x")) if self.speed.endswith("x") else 0.0
        except ValueError:
            rate = 0.0
        if rate <= 0:
            return None
        return max(0, round((self.duration - self.out_time) / rate))

    def as_dict(self) -> dict:
        return {
            "id": self.id,
            "gid": f"media:{self.id}",  # so a UI can key it like any download
            "name": self.name,
            "status": self.status,
            "progress": round(self.progress, 2),
            "completed": self.completed,
            "total": 0,
            "path": str(self.path),
            "duration": self.duration,
            "outTime": round(self.out_time, 2),
            "speed": self.speed,
            "eta": self.eta,
            "error": self.error,
            "quality": self.variant.get("quality", ""),
            "kind": self.variant.get("kind", ""),
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
        }


class MediaJobs:
    """Runs and tracks the ffmpeg jobs."""

    def __init__(self, on_event=None, max_parallel: int = 2, keep_finished: int = 30):
        self.jobs: dict[str, MediaJob] = {}
        self.on_event = on_event or (lambda level, message, **extra: None)
        self.max_parallel = max(1, max_parallel)
        self.keep_finished = keep_finished
        self._sem = asyncio.Semaphore(self.max_parallel)

    # ---- availability ---------------------------------------------------
    @staticmethod
    def ffmpeg_path() -> str | None:
        return shutil.which("ffmpeg")

    @staticmethod
    def ffprobe_path() -> str | None:
        return shutil.which("ffprobe")

    # ---- probing --------------------------------------------------------
    async def duration_of(self, url: str, headers: dict[str, str]) -> float | None:
        """How long the stream is, so progress can be a percentage.

        Without this a job can only report elapsed output time, which tells the
        user it is working but not how much is left.
        """
        ffprobe = self.ffprobe_path()
        if not ffprobe:
            return None
        argv = [ffprobe, "-v", "quiet", "-print_format", "json", "-show_format"]
        if blob := _ffmpeg_headers(headers):
            argv += ["-headers", blob]
        if ua := headers.get("User-Agent"):
            argv += ["-user_agent", ua]
        argv += [url]
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=25)
        except (OSError, asyncio.TimeoutError):
            return None
        try:
            value = json.loads(out or b"{}").get("format", {}).get("duration")
            return float(value) if value else None
        except (ValueError, json.JSONDecodeError, AttributeError):
            return None

    # ---- running --------------------------------------------------------
    def start(self, variant: dict, name: str, directory: str,
              headers: dict[str, str] | None = None) -> MediaJob:
        job_id = uuid.uuid4().hex[:12]
        path = Path(directory).expanduser() / name
        job = MediaJob(job_id, name, path, variant)
        self.jobs[job_id] = job
        asyncio.create_task(self._run(job, headers or {}))
        self._trim()
        return job

    def _argv(self, job: MediaJob, headers: dict[str, str]) -> list[str]:
        ffmpeg = self.ffmpeg_path()
        variant = job.variant
        argv = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y"]

        def source(url: str) -> list[str]:
            # Headers are positional in ffmpeg: they apply to the input that
            # follows, so an authenticated stream needs them repeated per input.
            part: list[str] = []
            if blob := _ffmpeg_headers(headers):
                part += ["-headers", blob]
            if ua := headers.get("User-Agent"):
                part += ["-user_agent", ua]
            return part + ["-i", url]

        argv += source(variant["url"])
        audio_url = variant.get("audioUrl") or ""
        if variant.get("needsAudio") and audio_url:
            argv += source(audio_url)
            argv += ["-map", "0:v:0", "-map", "1:a:0"]
        else:
            argv += ["-map", "0"]

        argv += [
            "-c", "copy",
            # HLS carries MPEG-TS timestamps that restart at discontinuities;
            # without this the muxed file has jumping timestamps and players
            # seek badly.
            "-bsf:a", "aac_adtstoasc",
            "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats",
            str(job.path),
        ]
        return argv

    async def _run(self, job: MediaJob, headers: dict[str, str]) -> None:
        if not self.ffmpeg_path():
            job.status = "error"
            job.error = "ffmpeg is not installed — it is what fetches and muxes a stream"
            job.finished_at = time.time()
            self.on_event("error", f"{job.name}: {job.error}")
            return

        async with self._sem:
            if job.status == "cancelled":
                return
            job.duration = await self.duration_of(job.variant["url"], headers)
            job.status = "running"
            job.path.parent.mkdir(parents=True, exist_ok=True)
            argv = self._argv(job, headers)
            try:
                job.proc = await asyncio.create_subprocess_exec(
                    *argv,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
            except OSError as exc:
                job.status = "error"
                job.error = str(exc)
                job.finished_at = time.time()
                self.on_event("error", f"{job.name}: {exc}")
                return

            self.on_event("info", f"Downloading {job.name} ({job.variant.get('quality', '')})")
            reader = asyncio.create_task(self._read_progress(job))
            stderr = await job.proc.stderr.read()
            code = await job.proc.wait()
            with contextlib.suppress(asyncio.CancelledError):
                reader.cancel()
                await reader

            job.finished_at = time.time()
            if job.status == "cancelled":
                self._discard(job)
                return
            if code == 0:
                job.status = "complete"
                job.progress = 100.0
                with contextlib.suppress(OSError):
                    job.completed = job.path.stat().st_size
                self.on_event("info", f"Finished {job.name}")
            else:
                job.status = "error"
                job.error = (stderr or b"").decode("utf-8", "replace").strip()[-400:] \
                    or f"ffmpeg exited with {code}"
                self.on_event("error", f"{job.name}: {job.error}")
                self._discard(job)

    async def _read_progress(self, job: MediaJob) -> None:
        """ffmpeg's -progress stream is plain key=value lines, one per block."""
        assert job.proc and job.proc.stdout
        while True:
            raw = await job.proc.stdout.readline()
            if not raw:
                return
            key, _, value = raw.decode("utf-8", "replace").strip().partition("=")
            if key == "out_time_ms":
                with contextlib.suppress(ValueError):
                    job.out_time = int(value) / 1_000_000
                    if job.duration:
                        job.progress = min(99.9, 100.0 * job.out_time / job.duration)
            elif key == "total_size":
                with contextlib.suppress(ValueError):
                    job.completed = int(value)
            elif key == "speed":
                job.speed = value.strip()

    def _discard(self, job: MediaJob) -> None:
        """A half-muxed container is not playable, so it does not stay behind."""
        with contextlib.suppress(OSError):
            if job.path.exists():
                job.path.unlink()

    # ---- control --------------------------------------------------------
    def cancel(self, job_id: str, delete_file: bool = True) -> bool:
        job = self.jobs.get(job_id)
        if not job or job.status in FINAL:
            return False
        job.status = "cancelled"
        if job.proc and job.proc.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                job.proc.terminate()
        if delete_file:
            self._discard(job)
        self.on_event("info", f"Cancelled {job.name}")
        return True

    def remove(self, job_id: str, delete_file: bool = False) -> bool:
        job = self.jobs.pop(job_id, None)
        if not job:
            return False
        if job.status not in FINAL:
            self.cancel(job_id, delete_file=True)
        elif delete_file:
            self._discard(job)
        return True

    def _trim(self) -> None:
        finished = sorted(
            (j for j in self.jobs.values() if j.status in FINAL),
            key=lambda j: j.finished_at or 0)
        for job in finished[:max(0, len(finished) - self.keep_finished)]:
            self.jobs.pop(job.id, None)

    async def shutdown(self) -> None:
        for job in list(self.jobs.values()):
            if job.status not in FINAL:
                self.cancel(job.id, delete_file=True)

    # ---- reporting ------------------------------------------------------
    def public_state(self) -> dict:
        jobs = sorted(self.jobs.values(), key=lambda j: j.started_at, reverse=True)
        return {
            "available": bool(self.ffmpeg_path()),
            "jobs": [job.as_dict() for job in jobs],
            "active": sum(1 for j in jobs if j.status == "running"),
        }
