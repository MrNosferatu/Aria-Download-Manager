"""Spawn, health-check and restart the aria2c child process."""

from __future__ import annotations

import asyncio
import contextlib
import os
import shutil
import signal
import time
from pathlib import Path
from typing import Callable

import aiohttp

from .config import Config, expand
from .rpc import Aria2Error, Aria2RPC


class SupervisorError(RuntimeError):
    pass


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class Aria2Supervisor:
    """Owns the aria2c process when ``aria2.managed`` is true.

    When unmanaged, it only probes an already-running aria2c so the rest of the
    app behaves identically.
    """

    def __init__(self, cfg: Config, rpc: Aria2RPC, on_event: Callable[..., None]):
        self.cfg = cfg
        self.rpc = rpc
        self.on_event = on_event
        self.proc: asyncio.subprocess.Process | None = None
        #: True when we attached to an aria2c that was already running (e.g. one
        #: orphaned by a closed terminal) instead of spawning our own.
        self.adopted: bool = False
        self.adopted_pid: int | None = None
        self.version: str = ""
        self.started_at: float = 0.0
        self.restarts: int = 0
        self.last_error: str = ""
        self._monitor_task: asyncio.Task | None = None
        self._stopping = False

    # ---- introspection ---------------------------------------------------
    @property
    def managed(self) -> bool:
        return bool(self.cfg.get("aria2.managed", True))

    def status(self) -> dict:
        running = self.proc is not None and self.proc.returncode is None
        if self.adopted:
            running = self.adopted_pid is None or _alive(self.adopted_pid)
        return {
            "managed": self.managed,
            "running": running if self.managed else bool(self.version),
            "adopted": self.adopted,
            "pid": (self.proc.pid if running and self.proc else None) or self.adopted_pid,
            "version": self.version,
            "rpc_url": self.rpc.url,
            "uptime": round(time.time() - self.started_at, 1) if self.started_at else 0,
            "restarts": self.restarts,
            "last_error": self.last_error,
            "log_file": self.cfg.get("aria2.log_file"),
            "session_file": self.cfg.get("aria2.session_file"),
        }

    # ---- argv ------------------------------------------------------------
    def _binary(self) -> str:
        binary = str(self.cfg.get("aria2.binary", "aria2c"))
        resolved = shutil.which(binary) or (binary if Path(binary).is_file() else None)
        if not resolved:
            raise SupervisorError(
                f"aria2c binary {binary!r} not found in PATH. "
                "Install it (Arch: sudo pacman -S aria2) or set aria2.binary in config.yaml."
            )
        return resolved

    def build_argv(self) -> list[str]:
        rpc = self.cfg.get("aria2.rpc", {})
        session = expand(self.cfg.get("aria2.session_file"))
        log_file = expand(self.cfg.get("aria2.log_file"))
        session.parent.mkdir(parents=True, exist_ok=True)
        log_file.parent.mkdir(parents=True, exist_ok=True)

        listen_all = str(rpc.get("host", "127.0.0.1")) not in ("127.0.0.1", "localhost")
        argv = [
            self._binary(),
            "--enable-rpc=true",
            f"--rpc-listen-all={'true' if listen_all else 'false'}",
            f"--rpc-listen-port={int(rpc.get('port', 6800))}",
            "--rpc-allow-origin-all=true",
            "--rpc-max-request-size=64M",
            f"--save-session={session}",
            "--save-session-interval=30",
            f"--log={log_file}",
            "--daemon=false",
            "--quiet=false",
        ]
        if rpc.get("secret"):
            argv.append(f"--rpc-secret={rpc['secret']}")
        if session.is_file() and session.stat().st_size > 0:
            argv.append(f"--input-file={session}")

        options: dict = self.cfg.get("aria2.options", {}) or {}
        if self.cfg.get("torrent.download_only"):
            # Download-only torrents: hold uploads at the floor from the start.
            from .seeding import UPLOAD_FLOOR
            options = {**options, "max-overall-upload-limit": UPLOAD_FLOOR}
        for key, value in options.items():
            if isinstance(value, (list, tuple)):
                argv.extend(f"--{key}={item}" for item in value)
            else:
                argv.append(f"--{key}={value}")

        dl_dir = options.get("dir")
        if dl_dir:
            Path(dl_dir).mkdir(parents=True, exist_ok=True)

        argv.extend(str(a) for a in (self.cfg.get("aria2.extra_args") or []))
        return argv

    # ---- an aria2c that outlived its manager ------------------------------
    def find_aria2_on_port(self, require_session: bool = False) -> int | None:
        """PID of an aria2c listening on our RPC port, via /proc.

        `require_session` additionally demands that it references *our* session
        file, which is what proves the process is one of ours rather than an
        unrelated aria2c someone else started on the same port.
        """
        port = int(self.cfg.get("aria2.rpc.port", 6800))
        session = str(self.cfg.get("aria2.session_file") or "")
        needle = f"--rpc-listen-port={port}"
        try:
            entries = list(Path("/proc").iterdir())
        except OSError:
            return None
        for entry in entries:
            if not entry.name.isdigit():
                continue
            try:
                cmdline = (entry / "cmdline").read_bytes().decode("utf-8", "replace")
            except OSError:
                continue
            if "aria2c" not in cmdline or needle not in cmdline:
                continue
            if require_session and session and session not in cmdline:
                continue
            return int(entry.name)
        return None

    async def _inspect_port(self, probe_timeout: float = 5.0) -> str:
        """Who owns our RPC port: 'free', 'ours', 'stale' or 'foreign'.

        Uses a short deadline of its own: a socket that accepts connections but
        never answers would otherwise hold up startup for the full RPC timeout.
        """
        try:
            info = await asyncio.wait_for(self.rpc.get_version(), timeout=probe_timeout)
            self.version = (info or {}).get("version", "?")
            return "ours"
        except asyncio.TimeoutError:
            return "foreign"
        except Aria2Error as exc:
            # It replied, but not usefully. A non-JSON reply is not aria2 at all.
            if "non-JSON" in str(exc):
                return "foreign"
            return "stale" if self.find_aria2_on_port(require_session=True) else "foreign"
        except (aiohttp.ClientConnectorError, ConnectionRefusedError, OSError):
            return "free"
        except aiohttp.ClientError:
            return "foreign"

    def _reclaim(self, pid: int) -> bool:
        """Stop an aria2c of ours that outlived its manager. SIGTERM saves its session."""
        self.on_event("warn", f"Reclaiming RPC port from a leftover aria2c (pid {pid})")
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.kill(pid, signal.SIGTERM)
        for _ in range(40):  # up to 8s for it to save its session and exit
            if not _alive(pid):
                return True
            time.sleep(0.2)
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.kill(pid, signal.SIGKILL)
        for _ in range(10):
            if not _alive(pid):
                return True
            time.sleep(0.2)
        return False

    # ---- lifecycle -------------------------------------------------------
    async def start(self) -> None:
        self._stopping = False
        if not self.managed:
            await self._wait_ready(float(self.cfg.get("aria2.startup_timeout", 20.0)))
            self.started_at = time.time()
            self.on_event("info", f"Attached to external aria2c {self.version}")
            return

        owner = await self._inspect_port()
        if owner == "ours":
            # An aria2c from a previous run is still going and still talks to us:
            # adopt it, downloads and all, rather than fighting for the port.
            self.adopted = True
            self.adopted_pid = self.find_aria2_on_port()
            self.started_at = time.time()
            self.on_event(
                "info",
                f"Adopted the aria2c already running on port "
                f"{self.cfg.get('aria2.rpc.port')} (version {self.version}"
                + (f", pid {self.adopted_pid}" if self.adopted_pid else "") + ")",
            )
            self._monitor_task = asyncio.create_task(self._monitor_adopted())
            return
        if owner == "stale":
            pid = self.find_aria2_on_port(require_session=True)
            if pid and not self._reclaim(pid):
                raise SupervisorError(
                    f"An old aria2c (pid {pid}) is holding RPC port "
                    f"{self.cfg.get('aria2.rpc.port')} and would not stop. "
                    "Kill it manually, or set a different aria2.rpc.port."
                )
        elif owner == "foreign":
            raise SupervisorError(
                f"Something else is already listening on RPC port "
                f"{self.cfg.get('aria2.rpc.port')} and it is not an aria2c of ours. "
                "Stop it, or set a different aria2.rpc.port in config.yaml."
            )

        argv = self.build_argv()
        self.on_event("info", "Starting aria2c…", detail=" ".join(argv[:6]) + " …")
        self.proc = await asyncio.create_subprocess_exec(
            *argv,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            start_new_session=True,
        )
        asyncio.create_task(self._drain_output())
        try:
            await self._wait_ready(float(self.cfg.get("aria2.startup_timeout", 20.0)))
        except Exception:
            await self._terminate()
            raise
        self.started_at = time.time()
        self.last_error = ""
        self.on_event(
            "info", f"aria2c {self.version} ready (pid {self.proc.pid})"
        )
        self._monitor_task = asyncio.create_task(self._monitor())

    async def _drain_output(self) -> None:
        """Surface aria2c's own stdout/stderr as manager events."""
        proc = self.proc
        if proc is None or proc.stdout is None:
            return
        while True:
            raw = await proc.stdout.readline()
            if not raw:
                return
            line = raw.decode("utf-8", "replace").rstrip()
            if not line:
                continue
            lowered = line.lower()
            if "error" in lowered or "exception" in lowered:
                self.last_error = line
                self.on_event("error", line, source="aria2c")
            elif "warn" in lowered:
                self.on_event("warn", line, source="aria2c")

    async def _wait_ready(self, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        last: Exception | None = None
        while time.monotonic() < deadline:
            if self.managed and self.proc is not None and self.proc.returncode is not None:
                raise SupervisorError(
                    f"aria2c exited during startup (code {self.proc.returncode}). "
                    f"Check {self.cfg.get('aria2.log_file')}"
                )
            try:
                info = await self.rpc.get_version()
                self.version = (info or {}).get("version", "?")
                return
            except Exception as exc:  # connection refused while it boots
                last = exc
                await asyncio.sleep(0.25)
        raise SupervisorError(f"aria2 RPC at {self.rpc.url} not reachable: {last}")

    async def _monitor_adopted(self) -> None:
        """Watch an adopted aria2c; if it goes away, start one of our own."""
        while not self._stopping:
            await asyncio.sleep(5)
            if self._stopping:
                return
            try:
                await self.rpc.get_version()
                continue
            except Exception:
                pass
            if self._stopping:
                return
            self.on_event("error", "The adopted aria2c disappeared; starting our own")
            self.adopted = False
            self.adopted_pid = None
            try:
                await self.start()
            except Exception as exc:
                self.last_error = str(exc)
                self.on_event("error", f"Could not start aria2c: {exc}")
            return

    async def _monitor(self) -> None:
        """Restart aria2c if it dies unexpectedly."""
        backoff = 1.0
        while not self._stopping:
            proc = self.proc
            if proc is None:
                return
            code = await proc.wait()
            if self._stopping:
                return
            self.last_error = f"aria2c exited with code {code}"
            self.on_event("error", self.last_error)
            if not self.cfg.get("aria2.restart_on_exit", True):
                return
            self.restarts += 1
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)
            try:
                argv = self.build_argv()
                self.proc = await asyncio.create_subprocess_exec(
                    *argv,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.STDOUT,
                    start_new_session=True,
                )
                asyncio.create_task(self._drain_output())
                await self._wait_ready(float(self.cfg.get("aria2.startup_timeout", 20.0)))
                self.started_at = time.time()
                backoff = 1.0
                self.on_event("info", f"aria2c restarted (pid {self.proc.pid})")
            except Exception as exc:
                self.on_event("error", f"aria2c restart failed: {exc}")

    async def _terminate(self) -> None:
        proc = self.proc
        if proc is None or proc.returncode is not None:
            return
        proc.terminate()
        try:
            await asyncio.wait_for(proc.wait(), timeout=8)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()

    async def stop(self) -> None:
        self._stopping = True
        if self._monitor_task:
            self._monitor_task.cancel()
            self._monitor_task = None
        if not self.managed:
            return
        if not self.cfg.get("aria2.stop_on_exit", True):
            # Leave it downloading; the next run adopts it via the stored secret.
            self.on_event(
                "info", "Leaving aria2c running (aria2.stop_on_exit is false)"
            )
            with contextlib.suppress(Exception):
                await self.rpc.save_session()
            return
        if self.adopted:
            with contextlib.suppress(Exception):
                await self.rpc.save_session()
            with contextlib.suppress(Exception):
                await self.rpc.shutdown()
            if self.adopted_pid:
                for _ in range(40):
                    if not _alive(self.adopted_pid):
                        break
                    await asyncio.sleep(0.2)
            self.adopted = False
            self.adopted_pid = None
            return
        if self.proc is not None and self.proc.returncode is None:
            try:
                await self.rpc.save_session()
                await self.rpc.shutdown()
                await asyncio.wait_for(self.proc.wait(), timeout=8)
            except Exception:
                await self._terminate()
        self.proc = None

    async def restart(self) -> None:
        await self.stop()
        self.restarts += 1
        await self.start()
