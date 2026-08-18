"""A tiny fake aria2 JSON-RPC server, for testing the manager without aria2c.

It simulates one HTTP download that deliberately stalls after a few seconds, so
the stall-recovery rule can be observed end to end. A pause/unpause cycle
"fixes" the stall, exactly like a real flaky server.

Run standalone:

    python3 tests/fake_aria2.py --port 6800
"""

from __future__ import annotations

import argparse
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NORMAL_SPEED = 2 * 1024 * 1024   # 2 MiB/s
STALL_SPEED = 8 * 1024           # 8 KiB/s — well under the 50 KiB/s rule


class FakeDownload:
    def __init__(self, gid: str, name: str, total: int, stall_after: float | None = None):
        self.gid = gid
        self.name = name
        self.total = total
        self.completed = 0
        self.status = "active"
        self.dir = "/tmp/fake-downloads"
        self.options: dict = {"split": "16", "max-connection-per-server": "16"}
        self.uris = [f"https://example.invalid/{name}"]
        self.created = time.time()
        self.stall_after = stall_after
        self.stalled_since: float | None = None
        self.pause_count = 0
        self.resume_count = 0
        self.error_code = "0"
        self.error_message = ""

    # ---- simulation ----------------------------------------------------
    @property
    def speed(self) -> int:
        if self.status != "active":
            return 0
        if self.stall_after is None:
            return NORMAL_SPEED
        age = time.time() - (self.stalled_since or self.created)
        return STALL_SPEED if age >= self.stall_after else NORMAL_SPEED

    def tick(self, dt: float) -> None:
        if self.status != "active":
            return
        self.completed = min(self.total, self.completed + int(self.speed * dt))
        if self.completed >= self.total:
            self.status = "complete"

    def pause(self) -> None:
        if self.status == "active":
            self.pause_count += 1
            self.status = "paused"

    def unpause(self) -> None:
        if self.status == "paused":
            self.resume_count += 1
            # Real aria2 moves it to *waiting*, not straight back to active: the
            # scheduler decides, subject to max-concurrent-downloads.
            self.status = "waiting"
            # A fresh connection cures the stall for another `stall_after`.
            self.stalled_since = time.time()

    # ---- wire format ---------------------------------------------------
    def to_dict(self, keys: list[str] | None = None) -> dict:
        pieces = max(1, self.total // (1024 * 1024))
        done_pieces = int(pieces * (self.completed / self.total)) if self.total else 0
        bits = "1" * done_pieces + "0" * (pieces - done_pieces)
        bitfield = "".join(
            f"{int(bits[i:i + 4].ljust(4, '0'), 2):x}" for i in range(0, len(bits), 4)
        )
        data = {
            "gid": self.gid,
            "status": self.status,
            "totalLength": str(self.total),
            "completedLength": str(self.completed),
            "uploadLength": "0",
            "downloadSpeed": str(self.speed),
            "uploadSpeed": "0",
            "connections": "8" if self.status == "active" else "0",
            "numSeeders": "0",
            "seeder": "false",
            "dir": self.dir,
            "numPieces": str(pieces),
            "pieceLength": str(1024 * 1024),
            "bitfield": bitfield,
            "errorCode": self.error_code,
            "errorMessage": self.error_message,
            "files": [
                {
                    "index": "1",
                    "path": os.path.join(self.dir, self.name),
                    "length": str(self.total),
                    "completedLength": str(self.completed),
                    "selected": "true",
                    "uris": [{"uri": uri, "status": "used"} for uri in self.uris],
                }
            ],
        }
        if keys:
            return {k: v for k, v in data.items() if k in keys}
        return data


class FakeAria2:
    def __init__(self, secret: str = ""):
        self.secret = secret
        self.downloads: dict[str, FakeDownload] = {}
        self.global_options = {
            "dir": "/tmp/fake-downloads",
            "max-concurrent-downloads": "5",
            "max-connection-per-server": "16",
            "split": "16",
            "min-split-size": "1M",
            "max-overall-download-limit": "0",
            "max-overall-upload-limit": "0",
            "continue": "true",
            "file-allocation": "prealloc",
        }
        self.queue: list[str] = []
        self._counter = 0
        self._stop = threading.Event()
        threading.Thread(target=self._ticker, daemon=True).start()

    def _ticker(self) -> None:
        last = time.time()
        while not self._stop.is_set():
            time.sleep(0.2)
            now = time.time()
            dt, last = now - last, now
            for dl in list(self.downloads.values()):
                dl.tick(dt)
            self._schedule()

    def _schedule(self) -> None:
        """Promote waiting downloads while below max-concurrent-downloads.

        This is what makes pausing an active download hand its slot to the next
        one in the queue, exactly as real aria2 does.
        """
        try:
            limit = max(1, int(self.global_options.get("max-concurrent-downloads", 5)))
        except (TypeError, ValueError):
            limit = 5
        active = [d for d in self.downloads.values() if d.status == "active"]
        if len(active) >= limit:
            return
        for gid in list(self.queue):
            if len(active) >= limit:
                return
            dl = self.downloads.get(gid)
            if dl is not None and dl.status == "waiting":
                dl.status = "active"
                dl.stalled_since = time.time()
                active.append(dl)

    def stop(self) -> None:
        self._stop.set()

    def new_gid(self) -> str:
        self._counter += 1
        return f"{self._counter:016x}"

    def add(self, name: str, total: int, stall_after: float | None = None, status: str = "active") -> FakeDownload:
        dl = FakeDownload(self.new_gid(), name, total, stall_after)
        dl.status = status
        self.downloads[dl.gid] = dl
        # Every download that is not already running belongs in the queue, and
        # active ones are tracked too so pause/unpause can reposition them.
        if dl.gid not in self.queue:
            self.queue.append(dl.gid)
        return dl

    # ---- rpc -----------------------------------------------------------
    def dispatch(self, method: str, params: list):
        if self.secret:
            if not params or params[0] != f"token:{self.secret}":
                raise PermissionError("Unauthorized")
            params = params[1:]

        if method == "aria2.getVersion":
            return {"version": "1.37.0-fake", "enabledFeatures": ["BitTorrent"]}

        if method == "aria2.tellActive":
            keys = params[0] if params else None
            return [d.to_dict(keys) for d in self.downloads.values() if d.status == "active"]

        if method in ("aria2.tellWaiting", "aria2.tellStopped"):
            keys = params[2] if len(params) > 2 else None
            wanted = ("waiting", "paused") if method.endswith("Waiting") else ("complete", "error", "removed")
            items = [d for d in self.downloads.values() if d.status in wanted]
            if method.endswith("Waiting"):
                order = {gid: i for i, gid in enumerate(self.queue)}
                items.sort(key=lambda d: order.get(d.gid, 999))
            return [d.to_dict(keys) for d in items]

        if method == "aria2.getGlobalStat":
            active = [d for d in self.downloads.values() if d.status == "active"]
            return {
                "downloadSpeed": str(sum(d.speed for d in active)),
                "uploadSpeed": "0",
                "numActive": str(len(active)),
                "numWaiting": str(len([d for d in self.downloads.values() if d.status in ("waiting", "paused")])),
                "numStopped": str(len([d for d in self.downloads.values() if d.status in ("complete", "error")])),
                "numStoppedTotal": str(len(self.downloads)),
            }

        if method == "aria2.addUri":
            uris, options = params[0], (params[1] if len(params) > 1 else {})
            name = options.get("out") or uris[0].rstrip("/").split("/")[-1] or "download"
            # Small on purpose: added downloads finish in ~2s so sequential
            # queue behaviour can be tested without long waits.
            dl = self.add(name, 4 * 1024 * 1024, status="paused" if options.get("pause") == "true" else "active")
            dl.uris = list(uris)
            dl.options.update(options)
            if options.get("dir"):
                dl.dir = options["dir"]
            return dl.gid

        if method == "aria2.addTorrent":
            dl = self.add("fake.torrent.payload", 700 * 1024 * 1024)
            return dl.gid

        if method == "aria2.tellStatus":
            dl = self._get(params[0])
            return dl.to_dict(params[1] if len(params) > 1 else None)

        if method in ("aria2.pause", "aria2.forcePause"):
            dl = self._get(params[0])
            was_active = dl.status == "active"
            dl.pause()
            if was_active:
                # "the download is placed in the front of waiting queue"
                if dl.gid in self.queue:
                    self.queue.remove(dl.gid)
                self.queue.insert(0, dl.gid)
            return dl.gid

        if method == "aria2.unpause":
            dl = self._get(params[0])
            dl.unpause()
            return dl.gid

        if method in ("aria2.remove", "aria2.forceRemove"):
            dl = self._get(params[0])
            dl.status = "removed"
            return dl.gid

        if method == "aria2.removeDownloadResult":
            gid = params[0]
            if gid not in self.downloads:
                raise KeyError(gid)
            self.downloads.pop(gid, None)
            return "OK"

        if method == "aria2.changeOption":
            dl = self._get(params[0])
            dl.options.update(params[1] or {})
            return "OK"

        if method == "aria2.getOption":
            return self._get(params[0]).options

        if method == "aria2.getGlobalOption":
            return dict(self.global_options)

        if method == "aria2.changeGlobalOption":
            self.global_options.update({k: str(v) for k, v in (params[0] or {}).items()})
            return "OK"

        if method == "aria2.getUris":
            return [{"uri": u, "status": "used"} for u in self._get(params[0]).uris]

        if method == "aria2.getFiles":
            return self._get(params[0]).to_dict()["files"]

        if method == "aria2.getServers":
            dl = self._get(params[0])
            if dl.status != "active":
                return []
            return [{
                "index": "1",
                "servers": [{
                    "uri": dl.uris[0],
                    "currentUri": dl.uris[0],
                    "downloadSpeed": str(dl.speed // 2),
                }] * 2,
            }]

        if method == "aria2.getPeers":
            return []

        if method == "aria2.changePosition":
            gid, pos, how = params[0], int(params[1]), params[2]
            if gid in self.queue:
                current = self.queue.index(gid)
                target = {"POS_SET": pos, "POS_CUR": current + pos, "POS_END": len(self.queue) + pos}[how]
                target = max(0, min(len(self.queue) - 1, target))
                self.queue.insert(target, self.queue.pop(current))
                return target
            return 0

        if method in ("aria2.pauseAll", "aria2.forcePauseAll"):
            for dl in self.downloads.values():
                dl.pause()
            return "OK"

        if method == "aria2.unpauseAll":
            for dl in self.downloads.values():
                dl.unpause()
            return "OK"

        if method == "aria2.purgeDownloadResult":
            for gid, dl in list(self.downloads.items()):
                if dl.status in ("complete", "error", "removed"):
                    del self.downloads[gid]
            return "OK"

        if method in ("aria2.saveSession", "aria2.shutdown", "aria2.forceShutdown"):
            return "OK"

        raise NotImplementedError(method)

    def _get(self, gid: str) -> FakeDownload:
        if gid not in self.downloads:
            raise KeyError(f"No such download: {gid}")
        return self.downloads[gid]


def make_handler(server: FakeAria2):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):  # keep test output clean
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            try:
                payload = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                self._send({"error": {"code": -32700, "message": "parse error"}}, status=400)
                return

            method = payload.get("method", "")
            params = payload.get("params", []) or []
            try:
                if method == "system.multicall":
                    results = []
                    for call in params[0]:
                        try:
                            results.append([server.dispatch(call["methodName"], call.get("params", []))])
                        except Exception as exc:
                            results.append({"faultCode": 1, "faultString": str(exc)})
                    result = results
                else:
                    result = server.dispatch(method, params)
            except Exception as exc:
                # Real aria2 (1.37) answers application errors with HTTP 400 and a
                # JSON-RPC error body. Mirroring that here is what makes the
                # client's error handling testable.
                self._send({"jsonrpc": "2.0", "id": payload.get("id"),
                            "error": {"code": 1, "message": str(exc)}}, status=400)
                return
            self._send({"jsonrpc": "2.0", "id": payload.get("id"), "result": result})

        def _send(self, body: dict, status: int = 200):
            raw = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    return Handler


def serve(port: int = 6800, secret: str = "", seed: bool = True) -> tuple[ThreadingHTTPServer, FakeAria2]:
    state = FakeAria2(secret)
    if seed:
        state.add("big.iso", 4 * 1024 * 1024 * 1024, stall_after=4.0)
        state.add("movie.mkv", 2 * 1024 * 1024 * 1024)
        state.add("queued.zip", 100 * 1024 * 1024, status="waiting")
    httpd = ThreadingHTTPServer(("127.0.0.1", port), make_handler(state))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, state


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Fake aria2 JSON-RPC server")
    parser.add_argument("--port", type=int, default=6800)
    parser.add_argument("--secret", default="")
    args = parser.parse_args()
    httpd, state = serve(args.port, args.secret)
    print(f"fake aria2 listening on http://127.0.0.1:{args.port}/jsonrpc")
    print("seeded: big.iso (stalls after 4s), movie.mkv, queued.zip")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        httpd.shutdown()
        state.stop()
