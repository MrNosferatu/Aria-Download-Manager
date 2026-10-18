"""A VPN for downloads only.

wireproxy runs WireGuard in user space and offers a local HTTP proxy. A
download that should use the VPN gets aria2's per-download ``all-proxy``
pointing at it; nothing else changes: not the rest of the system, not
torrents, not a download that goes direct. So download A can use the VPN
while B goes direct, at the same time, in the same aria2c.

Which downloads use it: none while the master switch is off. Otherwise a
download's own choice (``vpn: on`` or ``off`` among its options, from the
add dialog or its details), or for ``auto`` whether its site is on the list.
A download set to use it fails while the tunnel is down instead of going out
over the normal connection: its proxy address stays, only nothing behind it
answers.

Configs are WireGuard ``.conf`` files (Proton's, for one) in a folder. The
chosen one is copied into wireproxy's own config with a CheckAlive ping, so
``/readyz`` says whether the tunnel carries traffic, not merely whether
wireproxy runs. That copy holds the private key and is written for the user
alone.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import re
import shutil
import time
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit

import aiohttp

from .config import expand

#: The pseudo-option a front-end sends with a download: auto, on or off.
#: Taken out before aria2 sees the options.
CHOICE_KEY = "vpn"
CHOICES = ("auto", "on", "off")

DEFAULT_FOLDER = "~/.config/aria-download-manager/wireguard"


def site_of(entry: str) -> str:
    """A site as the list keeps it: a bare host, any scheme, path, port,
    ``*.`` or ``www.`` taken off ("https://www.mediafire.com/x" -> mediafire.com)."""
    text = str(entry or "").strip().lower()
    if "://" in text:
        text = urlsplit(text).hostname or ""
    text = text.split("/")[0].split(":")[0]
    for prefix in ("*.", "www."):
        if text.startswith(prefix):
            text = text[len(prefix):]
    return text.strip(".")


def host_of(url: str) -> str:
    try:
        return (urlsplit(str(url)).hostname or "").lower()
    except ValueError:
        return ""


def on_list(url: str, sites: list[str]) -> bool:
    """The link's host is a listed site or one of its subdomains."""
    host = host_of(url)
    return bool(host) and any(host == s or host.endswith("." + s) for s in sites if s)


def wireproxy_config(source: str, port: int) -> str:
    """wireproxy's config from a WireGuard one: the same [Interface] and
    [Peer], a CheckAlive ping through the tunnel (its DNS server, which
    Proton answers on, else 1.1.1.1), and the HTTP proxy for aria2."""
    lines = source.splitlines()
    dns = ""
    section = ""
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("["):
            section = stripped.lower()
        elif section == "[interface]" and re.match(r"(?i)dns\s*=", stripped):
            dns = stripped.split("=", 1)[1].split(",")[0].strip()
    target = dns if re.fullmatch(r"[0-9.]+", dns or "") else "1.1.1.1"
    out: list[str] = []
    for line in lines:
        # Our own ping and proxy only; any the file carries would clash.
        if re.match(r"(?i)\s*checkalive(interval)?\s*=", line):
            continue
        out.append(line)
        if line.strip().lower() == "[interface]":
            out += [f"CheckAlive = {target}", "CheckAliveInterval = 10"]
    out += ["", "[http]", f"BindAddress = 127.0.0.1:{port}", ""]
    return "\n".join(out)


class Vpn:
    def __init__(self, cfg, state_dir: Path,
                 on_event: Callable[..., None] = lambda *a, **k: None) -> None:
        self.cfg = cfg
        self.state_dir = Path(state_dir)
        self.on_event = on_event
        self.proc: asyncio.subprocess.Process | None = None
        self.connected = False
        self.connected_since = 0.0
        self.last_error = ""
        self.restarts = 0
        self._stopping = False
        self._tasks: list[asyncio.Task] = []
        #: Downloads aria2 holds that use the VPN, by gid, learnt from their
        #: options (so it holds across restarts of the manager).
        self.routed: dict[str, bool] = {}
        self._learning: set[str] = set()

    # ---- settings ---------------------------------------------------------
    @property
    def enabled(self) -> bool:
        return bool(self.cfg.get("vpn.enabled", False))

    def folder(self) -> Path:
        return expand(self.cfg.get("vpn.folder") or DEFAULT_FOLDER)

    def servers(self) -> list[str]:
        folder = self.folder()
        if not folder.is_dir():
            return []
        return sorted((p.name for p in folder.glob("*.conf") if p.is_file()), key=str.lower)

    @property
    def server(self) -> str:
        chosen = str(self.cfg.get("vpn.server") or "")
        servers = self.servers()
        return chosen if chosen in servers else (servers[0] if servers else "")

    def sites(self) -> list[str]:
        return [s for s in (site_of(x) for x in self.cfg.get("vpn.sites", []) or []) if s]

    @property
    def port(self) -> int:
        return int(self.cfg.get("vpn.port", 25345))

    @property
    def proxy_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def binary(self) -> str | None:
        name = str(self.cfg.get("vpn.binary", "wireproxy"))
        return shutil.which(name) or (name if Path(name).is_file() else None)

    def status(self) -> dict:
        return {
            "enabled": self.enabled,
            "installed": self.binary() is not None,
            "running": self.proc is not None and self.proc.returncode is None,
            "connected": self.connected,
            "connectedSince": self.connected_since or None,
            "server": self.server,
            "servers": self.servers(),
            "folder": str(self.folder()),
            "sites": self.sites(),
            "proxy": self.proxy_url,
            "lastError": self.last_error,
            "routed": sorted(g for g, on in self.routed.items() if on),
        }

    def save(self, enabled: Any = None, folder: str | None = None, server: str | None = None,
             sites: list[str] | None = None) -> None:
        for holder in (self.cfg.data, self.cfg._user):
            if not isinstance(holder.get("vpn"), dict):
                holder["vpn"] = {}
            section = holder["vpn"]
            if enabled is not None:
                section["enabled"] = bool(enabled)
            if folder is not None:
                section["folder"] = str(folder).strip() or DEFAULT_FOLDER
            if server is not None:
                section["server"] = os.path.basename(str(server))
            if sites is not None:
                seen: list[str] = []
                for site in (site_of(s) for s in sites):
                    if site and site not in seen:
                        seen.append(site)
                section["sites"] = seen
        self.cfg.save()

    # ---- choosing ---------------------------------------------------------
    def wants(self, url: str, choice: str = "auto") -> bool:
        if not self.enabled:
            return False
        choice = str(choice or "auto").lower()
        if choice == "on":
            return True
        if choice == "off":
            return False
        return on_list(url, self.sites())

    def route(self, uris: list[str], options: dict) -> dict:
        """The options for aria2: the choice taken out, ``all-proxy`` added
        when the VPN carries the download (mirrors: when it carries any).

        A proxy typed in for this download wins over the site list; only an
        explicit "on" puts the VPN in its place."""
        options = dict(options)
        choice = str(options.pop(CHOICE_KEY, "auto") or "auto").lower()
        if options.get("all-proxy") and choice != "on":
            return options
        if any(self.wants(uri, choice) for uri in uris):
            options["all-proxy"] = self.proxy_url
        return options

    def carries(self, options: dict) -> bool:
        """A download's aria2 options say it goes through the VPN."""
        return str(options.get("all-proxy") or "").rstrip("/") == self.proxy_url

    async def learn(self, rpc, gids: list[str]) -> None:
        """Find out, once per download, whether it uses the VPN."""
        for gid in gids:
            if gid in self.routed or gid in self._learning or gid.startswith("qb-"):
                continue
            self._learning.add(gid)
            try:
                self.routed[gid] = self.carries(await rpc.get_option(gid))
            except Exception:
                pass
            finally:
                self._learning.discard(gid)

    def observe(self, snapshot: dict, rpc) -> None:
        live = {d.get("gid") for d in snapshot.get("downloads", []) if d.get("gid")}
        for gone in [g for g in self.routed if g not in live]:
            del self.routed[gone]
        new = [g for g in live if g not in self.routed and not g.startswith("qb-")]
        if new:
            asyncio.ensure_future(self.learn(rpc, new[:20]))

    # ---- wireproxy --------------------------------------------------------
    @property
    def info_port(self) -> int:
        return self.port + 1

    def _write_config(self) -> Path:
        source = (self.folder() / self.server).read_text(encoding="utf-8")
        self.state_dir.mkdir(parents=True, exist_ok=True)
        path = self.state_dir / "wireproxy.conf"
        # It carries the private key: for this user alone, from the start.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(wireproxy_config(source, self.port))
        os.chmod(path, 0o600)
        return path

    async def start(self) -> None:
        self._stopping = False
        if not self.enabled:
            return
        binary = self.binary()
        if not binary:
            self.last_error = "wireproxy isn’t installed. Install it with: sudo pacman -S wireproxy"
            self.on_event("error", f"VPN: {self.last_error}")
            return
        if not self.server:
            self.last_error = f"No WireGuard config (.conf) found in {self.folder()}"
            self.on_event("error", f"VPN: {self.last_error}")
            return
        try:
            config = self._write_config()
        except OSError as exc:
            self.last_error = f"Couldn’t read {self.server}: {exc}"
            self.on_event("error", f"VPN: {self.last_error}")
            return
        await self._spawn(binary, config)
        self._tasks = [asyncio.create_task(self._monitor(binary, config)),
                       asyncio.create_task(self._watch())]
        self.on_event("info", f"Starting the VPN with {self.server}")

    async def _spawn(self, binary: str, config: Path) -> None:
        self.proc = await asyncio.create_subprocess_exec(
            binary, "-s", "-c", str(config), "-i", f"127.0.0.1:{self.info_port}",
            stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE)
        asyncio.create_task(self._drain(self.proc))

    async def _drain(self, proc) -> None:
        if proc.stderr is None:
            return
        while raw := await proc.stderr.readline():
            line = raw.decode("utf-8", "replace").strip()
            if line:
                self.last_error = line
                self.on_event("warn", f"VPN: {line}", source="wireproxy")

    async def _monitor(self, binary: str, config: Path) -> None:
        backoff = 1.0
        while not self._stopping and self.proc is not None:
            code = await self.proc.wait()
            if self._stopping:
                return
            self._set_connected(False)
            self.on_event("error", f"VPN: wireproxy exited with code {code}")
            self.restarts += 1
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)
            with contextlib.suppress(Exception):
                await self._spawn(binary, config)

    async def _watch(self) -> None:
        """Ask wireproxy every few seconds whether the tunnel answers."""
        url = f"http://127.0.0.1:{self.info_port}/readyz"
        timeout = aiohttp.ClientTimeout(total=3)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            while not self._stopping:
                ok = False
                with contextlib.suppress(Exception):
                    async with session.get(url) as res:
                        ok = res.status == 200
                self._set_connected(ok)
                await asyncio.sleep(2 if not ok else 5)

    def _set_connected(self, ok: bool) -> None:
        if ok == self.connected:
            return
        self.connected = ok
        if ok:
            self.connected_since = time.time()
            self.last_error = ""
            self.on_event("info", f"VPN connected via {self.server}")
        else:
            self.connected_since = 0.0
            if self.proc is not None:
                self.on_event("warn", "The VPN tunnel isn’t responding. Downloads that use it can’t connect until it’s back.")

    async def stop(self) -> None:
        self._stopping = True
        for task in self._tasks:
            task.cancel()
        self._tasks = []
        proc, self.proc = self.proc, None
        if proc is not None and proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), timeout=5)
            except asyncio.TimeoutError:
                proc.kill()
        self.connected = False
        self.connected_since = 0.0

    async def reload(self) -> None:
        await self.stop()
        self.last_error = ""
        await self.start()
