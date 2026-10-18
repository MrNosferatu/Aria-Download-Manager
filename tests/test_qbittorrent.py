"""qBittorrent as the torrent engine.

    python3 tests/test_qbittorrent.py

The helpers are checked on their own. The end-to-end part runs a real
qbittorrent-nox (skipped when it is not installed) next to the fake aria2, and
drives it through the manager's socket the way the UIs do. Nothing needs the
network: the torrents are made here, and their data is either already on disk
or never arrives.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import http.server
import os
import shutil
import sys
import tempfile
import threading
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
os.environ["XDG_DATA_HOME"] = tempfile.mkdtemp(prefix="aria-download-manager-test-data-")

from aria_download_manager import qbittorrent as qbt  # noqa: E402
from aria_download_manager.api import create_app  # noqa: E402
from aria_download_manager.config import Config  # noqa: E402
from tests.fake_aria2 import serve  # noqa: E402
from tests.harness import IPCSession, ManagerRunner, check, free_port, summary, wait_for  # noqa: E402


def bencode(value) -> bytes:
    if isinstance(value, int):
        return b"i%de" % value
    if isinstance(value, str):
        value = value.encode()
    if isinstance(value, bytes):
        return b"%d:%s" % (len(value), value)
    if isinstance(value, list):
        return b"l" + b"".join(bencode(v) for v in value) + b"e"
    if isinstance(value, dict):
        items = sorted((k.encode() if isinstance(k, str) else k, v) for k, v in value.items())
        return b"d" + b"".join(bencode(k) + bencode(v) for k, v in items) + b"e"
    raise TypeError(type(value))


PIECE = 16 * 1024


def make_torrent(name: str, files: dict[str, bytes]) -> tuple[bytes, str]:
    """A v1 multi-file torrent over ``files``; returns (torrent, its info hash)."""
    blob = b"".join(files.values())
    pieces = b"".join(hashlib.sha1(blob[i:i + PIECE]).digest() for i in range(0, len(blob), PIECE))
    info = {
        "name": name,
        "piece length": PIECE,
        "pieces": pieces,
        "files": [{"length": len(data), "path": [path]} for path, data in files.items()],
    }
    torrent = bencode({"announce": "http://127.0.0.1:9/announce", "info": info})
    return torrent, hashlib.sha1(bencode(info)).hexdigest()


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def test_units(tmp_dir: Path) -> None:
    print("\nunit: qBittorrent helpers")
    h = "c12fe1c06bba254a9dc9f519b335aa7c1367a88a"
    check("hex magnet hash", qbt.magnet_hash(f"magnet:?xt=urn:btih:{h.upper()}&dn=x") == h)
    b32 = base64.b32encode(bytes.fromhex(h)).decode()
    check("base32 magnet hash", qbt.magnet_hash(f"magnet:?xt=urn:btih:{b32}") == h)
    v2 = "a" * 64
    check("v2-only magnet hash is cut to 40", qbt.magnet_hash(f"magnet:?xt=urn:btmh:1220{v2}") == "a" * 40)
    check("no hash in a bare magnet", qbt.magnet_hash("magnet:?dn=nothing") == "")

    torrent, info_hash = make_torrent("pack", {"a.bin": b"a" * 100, "b.bin": b"b" * 50})
    check("torrent hash is SHA-1 of the info dict", qbt.torrent_hash(torrent) == info_hash)
    check("a page is not a torrent", not qbt.looks_like_torrent(b"<html>login</html>"))
    check("torrent links recognised", qbt.is_torrent_url("https://x.org/a/file.torrent?k=1")
          and not qbt.is_torrent_url("https://x.org/a/file.zip"))

    check("speeds parsed like aria2", qbt.parse_speed("2M") == 2 * 1024 ** 2
          and qbt.parse_speed("500K") == 500 * 1024 and qbt.parse_speed("0") == 0
          and qbt.parse_speed("1234") == 1234)
    check("priority levels map both ways",
          all(qbt.from_qb_priority(qbt.to_qb_priority(level)) == level for level in range(4)))
    check("qBittorrent's 'mixed' priority 4 reads as normal", qbt.from_qb_priority(4) == 1)
    check("states map to aria2 statuses",
          [qbt.status_of(s) for s in ("downloading", "pausedDL", "stoppedUP", "queuedDL", "missingFiles")]
          == ["active", "paused", "complete", "waiting", "error"])
    check("piece states bucketed", qbt.bucketize([2, 2, 1, 0], 2) == [100, 25])

    from aria_download_manager.api import disposition_name, probe_headers
    check("Content-Disposition names",
          disposition_name('attachment; filename="Report 2026.pdf"') == "Report 2026.pdf"
          and disposition_name("attachment; filename*=UTF-8''na%C3%AFve.zip") == "naïve.zip"
          and disposition_name('attachment; filename="../../etc/passwd"') == "passwd")
    ranged = probe_headers(206, {"Content-Range": "bytes 0-0/5000", "Content-Length": "1"})
    check("ranged probe: full size, resumable", ranged["size"] == 5000 and ranged["resumable"], str(ranged))
    plain = probe_headers(200, {"Content-Length": "77"})
    check("plain probe: size, not resumable", plain["size"] == 77 and not plain["resumable"], str(plain))

    conf = tmp_dir / "ini" / "qBittorrent.conf"
    conf.parent.mkdir()
    conf.write_text("[Preferences]\nWebUI\\Port=1\nOther=keep\n[BitTorrent]\nSession\\X=1\n")
    qbt.ensure_ini(conf, {"Preferences": {"WebUI\\Port": "8089", "WebUI\\LocalHostAuth": "false"},
                          "LegalNotice": {"Accepted": "true"}})
    text = conf.read_text()
    check("ini keys set, the rest kept",
          "WebUI\\Port=8089" in text and "Other=keep" in text and "Session\\X=1" in text
          and "WebUI\\LocalHostAuth=false" in text and "[LegalNotice]\nAccepted=true" in text
          and "WebUI\\Port=1\n" not in text, text)


# --------------------------------------------------------------------------
# end-to-end with a real qbittorrent-nox
# --------------------------------------------------------------------------
async def test_e2e(tmp_dir: Path) -> None:
    print("\ne2e: torrents through qbittorrent-nox")
    if not shutil.which("qbittorrent-nox"):
        print("  (skipped: qbittorrent-nox is not installed)")
        return
    rpc_port = free_port()
    httpd, _fake = serve(rpc_port, secret="s", seed=False)
    downloads = tmp_dir / "downloads"
    downloads.mkdir()

    # A torrent whose data is already on disk: qBittorrent checks it and is done.
    have_files = {"one.bin": os.urandom(40_000), "two.bin": os.urandom(30_000)}
    have, have_hash = make_torrent("have", have_files)
    (downloads / "have").mkdir()
    for path, data in have_files.items():
        (downloads / "have" / path).write_bytes(data)
    # One with three files and no data anywhere: it waits for peers forever.
    want, want_hash = make_torrent("want", {f"{n}.bin": os.urandom(20_000) for n in ("a", "b", "c")})
    # A third, served over HTTP as a .torrent link.
    linked, linked_hash = make_torrent("linked", {"l.bin": os.urandom(10_000)})
    web_dir = tmp_dir / "web"
    web_dir.mkdir()
    (web_dir / "linked.torrent").write_bytes(linked)
    (web_dir / "notreally.torrent").write_text("<html>please log in</html>")
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def guess_type(self, path):
            # Stands in for a site that answers a file link with a web page.
            return "text/html" if "/pages/" in str(path) else super().guess_type(path)

    handler = lambda *a, **kw: Quiet(*a, directory=str(web_dir), **kw)  # noqa: E731
    web = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=web.serve_forever, daemon=True).start()
    web_url = f"http://127.0.0.1:{web.server_address[1]}"

    config_path = tmp_dir / "config.yaml"
    config_path.write_text(yaml.safe_dump({
        "server": {"socket": str(tmp_dir / "manager.sock")},
        "poll_interval": 0.5,
        "aria2": {"managed": False,
                  "rpc": {"host": "127.0.0.1", "port": rpc_port, "secret": "s"},
                  "options": {"dir": str(downloads)}},
        "history": {"enabled": True, "file": str(tmp_dir / "history.json")},
        "torrent": {"engine": "auto", "download_only": True},
        "qbittorrent": {"port": free_port(), "profile": str(tmp_dir / "qbt")},
        "rules_enabled": False,
    }))
    cfg = Config(config_path)
    app = create_app(cfg)
    runner = ManagerRunner(app)
    task = asyncio.create_task(runner.serve())
    qb_proc = None
    try:
        async with IPCSession(cfg.get("server.socket")) as http_:
            async def call(method, path, body=None):
                res = await http_.call(method, path, body, timeout=60)
                return res.status, await res.json()

            check("manager came up", await wait_for(lambda: runner.started, 60))
            qb_proc = app.state.qb.supervisor.proc
            status, state = await call("GET", "/api/state")
            check("qBittorrent reported running in the snapshot",
                  await wait_for(lambda: app.state.store.snapshot.get("qbittorrent", {}).get("running"), 10),
                  str(state.get("qbittorrent")))
            _, ping = await call("GET", "/api/intake/ping")
            check("intake ping names the torrent engine", ping.get("torrentEngine") == "qbittorrent", str(ping))

            def row(gid):
                return next((d for d in app.state.store.snapshot.get("downloads", []) if d["gid"] == gid), None)

            # ---- a .torrent file -----------------------------------------------
            status, body = await call("POST", "/api/downloads/file",
                                      {"data": base64.b64encode(want).decode(), "filename": "want.torrent"})
            want_gid = qbt.gid_for(want_hash)
            check("a .torrent goes to qBittorrent", status == 200 and body["gids"] == [want_gid], str(body))
            check("its row shows up shaped like aria2's",
                  await wait_for(lambda: (row(want_gid) or {}).get("numFiles") == 3, 20), str(row(want_gid)))
            r = row(want_gid) or {}
            check("row fields", r.get("engine") == "qbittorrent" and r.get("isTorrent")
                  and r.get("total") == 60_000 and r.get("status") in ("active", "waiting"), str(r))
            check("download-only applies to new torrents", r.get("downloadOnly") is True, str(r))

            # ---- per-file priorities -------------------------------------------
            status, body = await call("POST", f"/api/download/{want_gid}/files",
                                      {"levels": {"1": 0, "2": 3, "3": 2}})
            check("file priorities accepted", status == 200, str(body))
            _, detail = await call("GET", f"/api/download/{want_gid}")
            check("detail reports real per-file priorities",
                  [f["priority"] for f in detail["files"]] == [0, 3, 2], str(detail.get("files")))
            check("skipped file is deselected",
                  [f["selected"] for f in detail["files"]] == ["false", "true", "true"])
            # qBittorrent counts the whole pieces the wanted files touch.
            check("skipped bytes stop counting",
                  await wait_for(lambda: 40_000 <= (row(want_gid) or {}).get("total", 0) < 60_000, 10),
                  str(row(want_gid)))
            status, body = await call("POST", f"/api/download/{want_gid}/files", {"levels": {"1": 0, "2": 0, "3": 0}})
            _, detail = await call("GET", f"/api/download/{want_gid}")
            check("skipping every file is allowed: qBittorrent keeps what it has",
                  status == 200 and [f["priority"] for f in detail["files"]] == [0, 0, 0], f"{body} {detail.get('files')}")
            status, _ = await call("POST", f"/api/download/{want_gid}/select", {"indices": [1, 3]})
            _, detail = await call("GET", f"/api/download/{want_gid}")
            check("plain selection maps to normal/skip",
                  [f["priority"] for f in detail["files"]] == [1, 0, 1], str(detail.get("files")))

            # ---- options ---------------------------------------------------------
            status, body = await call("POST", f"/api/download/{want_gid}/options",
                                      {"options": {qbt.SEQUENTIAL: "true", "max-download-limit": "1M",
                                                   "download-only": "false"}})
            check("per-torrent options applied", status == 200 and qbt.SEQUENTIAL in body["applied"], str(body))
            _, detail = await call("GET", f"/api/download/{want_gid}")
            opts = detail["options"]
            check("sequential download on", opts[qbt.SEQUENTIAL] == "true", str(opts))
            check("download limit set", opts["max-download-limit"] == str(1024 ** 2), str(opts))
            check("download-only switched off for this one", opts["download-only"] == "false", str(opts))
            status, body = await call("POST", f"/api/download/{want_gid}/options", {"options": {"split": "4"}})
            check("aria2-only options are refused for a torrent", status == 400, str(body))

            # ---- pause / resume ----------------------------------------------------
            await call("POST", f"/api/download/{want_gid}/pause")
            check("paused", await wait_for(lambda: (row(want_gid) or {}).get("status") == "paused", 10),
                  str(row(want_gid)))
            await call("POST", f"/api/download/{want_gid}/resume")
            check("resumed", await wait_for(lambda: (row(want_gid) or {}).get("status") in ("active", "waiting"), 10),
                  str(row(want_gid)))

            # ---- data already there: finishes, and download-only stops it -------
            status, body = await call("POST", "/api/downloads/file",
                                      {"data": base64.b64encode(have).decode(), "filename": "have.torrent"})
            have_gid = qbt.gid_for(have_hash)
            check("complete torrent ends up complete, not seeding",
                  await wait_for(lambda: (row(have_gid) or {}).get("status") == "complete", 30),
                  str(row(have_gid)))
            check("its files are reported", (row(have_gid) or {}).get("fileExists") is True, str(row(have_gid)))

            # ---- a finished torrent given more files starts again ------------------
            part_files = {"a.bin": os.urandom(32768), "b.bin": os.urandom(32768)}
            part, part_hash = make_torrent("part", part_files)
            (downloads / "part").mkdir()
            (downloads / "part" / "a.bin").write_bytes(part_files["a.bin"])
            await call("POST", "/api/downloads/file", {"data": base64.b64encode(part).decode(), "paused": True})
            part_gid = qbt.gid_for(part_hash)
            await wait_for(lambda: row(part_gid) is not None, 10)
            await call("POST", f"/api/download/{part_gid}/files", {"levels": {"1": 1, "2": 0}})
            await call("POST", f"/api/download/{part_gid}/resume")
            check("the chosen part finishes",
                  await wait_for(lambda: (row(part_gid) or {}).get("status") == "complete", 30), str(row(part_gid)))
            status, body = await call("POST", f"/api/download/{part_gid}/files", {"levels": {"1": 1, "2": 1}})
            check("choosing another file of a finished torrent downloads it",
                  status == 200 and await wait_for(lambda: (row(part_gid) or {}).get("status") == "active", 10),
                  str(row(part_gid)))
            _, detail = await call("GET", f"/api/download/{part_gid}")
            check("and the new priority stuck", [f["priority"] for f in detail["files"]] == [1, 1],
                  str(detail.get("files")))

            # ---- magnets ----------------------------------------------------------
            magnet_hash = hashlib.sha1(b"nobody has this").hexdigest()
            status, body = await call("POST", "/api/downloads", {
                "uris": [f"magnet:?xt=urn:btih:{magnet_hash}&dn=ghost", "http://example.invalid/x.zip"],
                "options": {"pause-metadata": "true"}})
            gids = body.get("gids") or []
            check("magnet to qBittorrent, the rest to aria2",
                  status == 200 and len(gids) == 2 and gids[0] == qbt.gid_for(magnet_hash)
                  and not qbt.is_gid(gids[1]), str(body))
            check("a magnet waiting on metadata is marked as such",
                  await wait_for(lambda: (row(gids[0]) or {}).get("isMetadata") is True, 10), str(row(gids[0])))
            status, body = await call("POST", "/api/downloads", {"uris": [f"magnet:?xt=urn:btih:{magnet_hash}"]})
            check("adding it twice gives the same torrent", body.get("gids") == [gids[0]], str(body))

            # ---- what the download dialog relies on -------------------------------
            status, body = await call("POST", "/api/intake/add", {
                "url": f"magnet:?xt=urn:btih:{magnet_hash}", "options": {"pause-metadata": "true"}})
            check("intake says when a torrent was already there",
                  body.get("existing") == [gids[0]], str(body))
            status, body = await call("POST", "/api/intake/probe", {"url": f"{web_url}/linked.torrent"})
            check("probe spots a torrent link", body.get("kind") == "torrent" and body.get("size") == len(linked),
                  str(body))
            (web_dir / "pages").mkdir()
            (web_dir / "pages" / "driver.exe").write_text("<!DOCTYPE html><html>verify you're human</html>")
            status, body = await call("POST", "/api/intake/probe", {"url": f"{web_url}/pages/driver.exe"})
            check("probe flags a file link that answers with a page, keeping the link's name",
                  body.get("page") is True and body.get("name") == "driver.exe", str(body))
            status, body = await call("POST", "/api/intake/probe", {"url": f"{web_url}/linked.torrent"})
            check("a real file is not a page", body.get("page") is False, str(body))
            status, body = await call("POST", "/api/intake/probe", {"url": "magnet:?xt=urn:btih:00&dn=Show"})
            check("probe names a magnet", body.get("kind") == "torrent" and body.get("name") == "Show", str(body))
            status, body = await call("POST", "/api/intake/probe", {"url": "http://127.0.0.1:9/nothing.zip"})
            check("an unreachable probe still answers", status == 200 and body.get("size") is None
                  and body.get("name") == "nothing.zip" and body.get("error"), str(body))

            status, body = await call("GET", "/api/folders?name=movie.mkv")
            check("folders list the download folder first", status == 200
                  and body["presets"][0]["path"] == str(downloads) and body["sorting"] is False, str(body))
            check("the folder for the file's type is suggested even with sorting off",
                  body["suggested"] == str(downloads / "Video")
                  and any(p["path"] == str(downloads / "Archives") for p in body["presets"]), str(body))

            # ---- .torrent links from the browser ---------------------------------
            status, body = await call("POST", "/api/intake/add", {
                "url": f"{web_url}/linked.torrent", "cookie": "session=1", "referer": web_url})
            check("a .torrent link is fetched and handed to qBittorrent",
                  status == 200 and body.get("gids") == [qbt.gid_for(linked_hash)], str(body))
            (web_dir / "download.php").write_bytes(make_torrent("named", {"n.bin": b"n" * 999})[0])
            status, body = await call("POST", "/api/intake/add", {
                "url": f"{web_url}/download.php", "filename": "named.torrent"})
            check("a link the browser named .torrent goes to qBittorrent",
                  status == 200 and qbt.is_gid((body.get("gids") or [""])[0]), str(body))
            status, body = await call("POST", "/api/intake/add", {"url": f"{web_url}/notreally.torrent"})
            check("a 'torrent' link that is really a page stays with aria2",
                  status == 200 and len(body.get("gids") or []) == 1 and not qbt.is_gid(body["gids"][0]), str(body))

            # ---- the global download-only switch reaches qBittorrent ---------------
            prefs = await app.state.qb.client.preferences()
            check("download-only on: qBittorrent stops at ratio 0, uploads at the floor",
                  prefs.get("max_ratio_enabled") and prefs.get("max_ratio") == 0
                  and prefs.get("up_limit") == qbt.UPLOAD_FLOOR, str(prefs.get("max_ratio")))
            status, _ = await call("POST", "/api/global/options",
                                   {"options": {"download-only": "false", "max-overall-download-limit": "2M"}})
            prefs = await app.state.qb.client.preferences()
            check("download-only off: seeding to the configured ratio, no upload cap",
                  status == 200 and prefs.get("max_ratio") == 1.0 and prefs.get("up_limit") == 0
                  and not prefs.get("max_seeding_time_enabled"), str(prefs.get("max_ratio")))
            check("global download limit mirrored", prefs.get("dl_limit") == 2 * 1024 ** 2,
                  str(prefs.get("dl_limit")))

            # ---- removing -----------------------------------------------------------
            status, _ = await call("DELETE", f"/api/download/{have_gid}?delete_files=true")
            check("removed with its files", status == 200
                  and await wait_for(lambda: not (downloads / "have").exists(), 10)
                  and await wait_for(lambda: row(have_gid) is None, 10))
            status, body = await call("POST", "/api/downloads/bulk",
                                      {"gids": [want_gid, gids[0]], "action": "remove"})
            check("bulk remove covers qBittorrent torrents", status == 200 and len(body["done"]) == 2, str(body))
            status, body = await call("GET", "/api/download/qb-" + "0" * 40)
            check("unknown torrent is a 404", status == 404, str(body))
    finally:
        runner.stop()
        await asyncio.wait_for(task, 60)
        httpd.shutdown()
        web.shutdown()
    check("managed qbittorrent-nox stopped with the manager",
          qb_proc is not None and qb_proc.returncode is not None)


async def main() -> int:
    tmp_dir = Path(tempfile.mkdtemp(prefix="aria-download-manager-qbt-"))
    try:
        test_units(tmp_dir)
        await test_e2e(tmp_dir)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
    return summary()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
