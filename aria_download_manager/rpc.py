"""Thin async client for the aria2 JSON-RPC interface (HTTP transport)."""

from __future__ import annotations

import asyncio
import itertools
import json
from typing import Any, Callable, Iterable, Sequence

import aiohttp

# Keys requested from tell*; keeps payloads small and stable.
STATUS_KEYS = [
    "gid",
    "status",
    "totalLength",
    "completedLength",
    "uploadLength",
    "downloadSpeed",
    "uploadSpeed",
    "connections",
    "numSeeders",
    "seeder",
    "dir",
    "files",
    "bittorrent",
    "errorCode",
    "errorMessage",
    "following",
    "followedBy",
    "belongsTo",
    "numPieces",
    "pieceLength",
    "verifiedLength",
    "infoHash",
]

DETAIL_KEYS = STATUS_KEYS + ["bitfield"]


class Aria2Error(Exception):
    def __init__(self, code: int | str, message: str, method: str = ""):
        self.code = code
        self.message = message
        self.method = method
        super().__init__(f"{method or 'aria2'}: [{code}] {message}")


class Aria2RPC:
    def __init__(self, host: str, port: int, secret: str = "", timeout: float = 30.0):
        self.host = host
        self.port = port
        self.secret = secret
        self.timeout = timeout
        self._ids = itertools.count(1)
        self._session: aiohttp.ClientSession | None = None
        self._lock = asyncio.Lock()
        #: Applied to the options of every download added through this client,
        #: whichever part of the manager adds it (see seeding.DownloadOnly).
        #: (options, uris, torrent) -> options
        self.prepare_add: Callable[..., dict] | None = None

    def _prepared(self, options: dict | None, uris: Any = None, torrent: Any = None) -> dict:
        options = dict(options or {})
        if not self.prepare_add:
            return options
        return self.prepare_add(options, uris=uris, torrent=torrent)

    @property
    def url(self) -> str:
        host = "127.0.0.1" if self.host in ("0.0.0.0", "::", "") else self.host
        return f"http://{host}:{self.port}/jsonrpc"

    async def start(self) -> None:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=self.timeout)
            )

    async def close(self) -> None:
        if self._session and not self._session.closed:
            await self._session.close()
        self._session = None

    def _params(self, params: Sequence[Any]) -> list[Any]:
        base: list[Any] = [f"token:{self.secret}"] if self.secret else []
        base.extend(params)
        return base

    async def _post(self, payload: Any) -> Any:
        """POST a JSON-RPC payload and return the decoded reply.

        aria2 answers *application* errors with HTTP 400 and a valid JSON-RPC
        error body (e.g. 400 + {"error": {"code": 1, "message": "GID … is not
        found"}}). So the body is parsed first and the status is only consulted
        when there is no JSON to read — otherwise a routine "already removed"
        would surface as a transport failure.
        """
        await self.start()
        assert self._session is not None
        async with self._session.post(self.url, json=payload) as resp:
            text = await resp.text()
            try:
                return json.loads(text)
            except (json.JSONDecodeError, ValueError):
                resp.raise_for_status()
                raise Aria2Error(
                    resp.status, f"non-JSON reply from aria2: {text[:200]!r}"
                ) from None

    async def call(self, method: str, *params: Any) -> Any:
        body = {
            "jsonrpc": "2.0",
            "id": f"m{next(self._ids)}",
            "method": method,
            "params": self._params(params),
        }
        data = await self._post(body)
        if isinstance(data, dict) and "error" in data:
            err = data["error"] or {}
            raise Aria2Error(err.get("code", -1), err.get("message", "unknown"), method)
        return data.get("result") if isinstance(data, dict) else data

    async def multicall(self, calls: Iterable[tuple[str, Sequence[Any]]]) -> list[Any]:
        """Batch several aria2 calls. Faults yield ``None`` in that slot."""
        calls = list(calls)
        if not calls:
            return []
        spec = [
            {"methodName": method, "params": self._params(params)}
            for method, params in calls
        ]
        body = {
            "jsonrpc": "2.0",
            "id": f"mc{next(self._ids)}",
            "method": "system.multicall",
            "params": [spec],
        }
        data = await self._post(body)
        if isinstance(data, dict) and "error" in data:
            err = data["error"] or {}
            raise Aria2Error(err.get("code", -1), err.get("message", "unknown"), "system.multicall")
        results = (data or {}).get("result") or []
        out: list[Any] = []
        for item in results:
            if isinstance(item, list):
                out.append(item[0] if item else None)
            else:  # {'faultCode':…, 'faultString':…}
                out.append(None)
        return out

    # ---- convenience wrappers ------------------------------------------
    async def get_version(self) -> dict:
        return await self.call("aria2.getVersion")

    async def add_uri(
        self,
        uris: Sequence[str],
        options: dict | None = None,
        position: int | None = None,
    ) -> str:
        params: list[Any] = [list(uris), self._prepared(options, uris=list(uris))]
        if position is not None:
            params.append(int(position))
        return await self.call("aria2.addUri", *params)

    async def add_torrent(
        self,
        torrent_b64: str,
        uris: Sequence[str] | None = None,
        options: dict | None = None,
        position: int | None = None,
    ) -> str:
        params: list[Any] = [torrent_b64, list(uris or []),
                             self._prepared(options, torrent=torrent_b64)]
        if position is not None:
            params.append(int(position))
        return await self.call("aria2.addTorrent", *params)

    async def add_metalink(
        self, metalink_b64: str, options: dict | None = None, position: int | None = None
    ) -> list[str]:
        params: list[Any] = [metalink_b64, self._prepared(options)]
        if position is not None:
            params.append(int(position))
        return await self.call("aria2.addMetalink", *params)

    async def tell_status(self, gid: str, keys: Sequence[str] | None = None) -> dict:
        if keys:
            return await self.call("aria2.tellStatus", gid, list(keys))
        return await self.call("aria2.tellStatus", gid)

    async def pause(self, gid: str, force: bool = False) -> str:
        return await self.call("aria2.forcePause" if force else "aria2.pause", gid)

    async def unpause(self, gid: str) -> str:
        return await self.call("aria2.unpause", gid)

    async def remove(self, gid: str, force: bool = False) -> str:
        return await self.call("aria2.forceRemove" if force else "aria2.remove", gid)

    async def remove_result(self, gid: str) -> str:
        return await self.call("aria2.removeDownloadResult", gid)

    async def change_option(self, gid: str, options: dict) -> str:
        return await self.call("aria2.changeOption", gid, options)

    async def get_option(self, gid: str) -> dict:
        return await self.call("aria2.getOption", gid)

    async def change_global_option(self, options: dict) -> str:
        return await self.call("aria2.changeGlobalOption", options)

    async def get_global_option(self) -> dict:
        return await self.call("aria2.getGlobalOption")

    async def change_position(self, gid: str, pos: int, how: str = "POS_SET") -> int:
        return await self.call("aria2.changePosition", gid, int(pos), how)

    async def get_uris(self, gid: str) -> list[dict]:
        return await self.call("aria2.getUris", gid)

    async def get_files(self, gid: str) -> list[dict]:
        return await self.call("aria2.getFiles", gid)

    async def get_peers(self, gid: str) -> list[dict]:
        return await self.call("aria2.getPeers", gid)

    async def pause_all(self, force: bool = False) -> str:
        return await self.call("aria2.forcePauseAll" if force else "aria2.pauseAll")

    async def unpause_all(self) -> str:
        return await self.call("aria2.unpauseAll")

    async def purge_results(self) -> str:
        return await self.call("aria2.purgeDownloadResult")

    async def save_session(self) -> str:
        return await self.call("aria2.saveSession")

    async def shutdown(self, force: bool = False) -> str:
        return await self.call("aria2.forceShutdown" if force else "aria2.shutdown")
