"""End-to-end checks for Aria Download Manager, driven against tests/fake_aria2.py.

    python3 tests/test_manager.py

No aria2c installation needed: the manager attaches to the fake RPC server in
unmanaged mode. The interesting assertion is the last one — the stall-recovery
rule must actually pause and resume a download whose speed drops.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
# The state dir (RPC secret, history) is fixed when the package is imported, so it
# has to point somewhere disposable before that, not at the real one.
os.environ["XDG_DATA_HOME"] = tempfile.mkdtemp(prefix="aria-download-manager-test-data-")

from aria_download_manager.api import clean_options, create_app, piece_map, split_uris  # noqa: E402
from aria_download_manager.config import Config  # noqa: E402
from aria_download_manager.config import DEFAULTS  # noqa: E402

# These suites drive aria2c (real or fake). Torrents would otherwise go to a
# qbittorrent-nox if one happens to be installed; tests/test_qbittorrent.py
# covers that engine.
DEFAULTS["torrent"]["engine"] = "aria2"
from tests.fake_aria2 import serve  # noqa: E402
from tests.harness import IPCSession, ManagerRunner, check, free_port, summary, wait_for  # noqa: E402


# --------------------------------------------------------------------------
# pure-function tests
# --------------------------------------------------------------------------
def test_units() -> None:
    print("\nunit: helpers")
    check("clean_options stringifies and drops blanks",
          clean_options({"split": 8, "continue": True, "dir": "  ", "x": None}) ==
          {"split": "8", "continue": "true"})
    check("clean_options keeps header lists",
          clean_options({"header": ["A: 1", "", "B: 2"]}) == {"header": ["A: 1", "B: 2"]})
    check("clean_options strips leading dashes",
          clean_options({"--split": 4}) == {"split": "4"})
    check("split_uris splits lines and dedupes",
          split_uris(["a\nb", " b "], "c") == ["a", "b", "c"])
    check("piece_map of a full bitfield is all 100",
          piece_map("ff", 8, buckets=4) == [100, 100, 100, 100])
    check("piece_map of an empty bitfield is all 0",
          piece_map("00", 8, buckets=4) == [0, 0, 0, 0])
    check("piece_map handles a half-done bitfield",
          piece_map("f0", 8, buckets=2) == [100, 0])
    check("piece_map tolerates no bitfield", piece_map("", 0) == [])

    print("\nunit: deleting a download's files")
    from aria_download_manager import files as filetools

    root = Path(tempfile.mkdtemp())
    folder = root / "torrent-folder"
    folder.mkdir()
    (folder / "a.bin").write_bytes(b"x" * 100)
    (folder / "b.bin").write_bytes(b"y" * 50)
    (folder / "a.bin.aria2").write_bytes(b"ctrl")
    result = filetools.delete([str(folder / "a.bin"), str(folder / "b.bin")], roots=[str(root)])
    check("deletes the files and their .aria2 control files",
          sorted(Path(p).name for p in result["deleted"]) == ["a.bin", "a.bin.aria2", "b.bin"],
          str(result))
    check("reports a control file that was never written as missing",
          [Path(p).name for p in result["missing"]] == ["b.bin.aria2"], str(result))
    check("counts the bytes it freed", result["bytes"] == 154, str(result["bytes"]))
    check("prunes the folder a multi-file torrent emptied", not folder.exists())

    outside = Path(tempfile.mkdtemp())
    precious = outside / "precious.txt"
    precious.write_text("keep me")
    refused = filetools.delete([str(precious)], roots=[str(root)])
    check("refuses a path outside the download roots",
          refused["deleted"] == [] and len(refused["refused"]) == 2, str(refused))
    check("and leaves that file alone", precious.exists())

    a_dir = root / "a-directory"
    a_dir.mkdir()
    dir_result = filetools.delete([str(a_dir)], roots=[str(root)])
    check("refuses to delete a directory", dir_result["deleted"] == [] and a_dir.is_dir(),
          str(dir_result))

    check("no roots means nothing is confined away",
          filetools.delete([], roots=[])["deleted"] == [])
    shutil.rmtree(root, ignore_errors=True)
    shutil.rmtree(outside, ignore_errors=True)

    print("\nunit: reading a stream manifest")
    from aria_download_manager import media as mediatools

    hls_master = "\n".join([
        "#EXTM3U",
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="audio/en.m3u8"',
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Japanese",LANGUAGE="ja",DEFAULT=NO,URI="audio/ja.m3u8"',
        '#EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=1280x720,FRAME-RATE=30.000,AUDIO="aud"',
        "v/720.m3u8",
        '#EXT-X-STREAM-INF:BANDWIDTH=5200000,RESOLUTION=1920x1080,FRAME-RATE=59.940,AUDIO="aud"',
        "v/1080.m3u8",
    ])
    probe = mediatools.parse(hls_master, "https://cdn.test/media/master.m3u8",
                             "application/vnd.apple.mpegurl")
    check("HLS master yields one variant per stream", len(probe.variants) == 2, str(probe.as_dict()))
    check("variants come back best-first",
          [v.quality() for v in probe.variants] == ["1080p60", "720p"],
          str([v.quality() for v in probe.variants]))
    check("a high frame rate is part of the quality name",
          probe.variants[0].quality() == "1080p60")
    check("relative stream URLs resolve against the manifest",
          probe.variants[1].url == "https://cdn.test/media/v/720.m3u8", probe.variants[1].url)
    check("the DEFAULT audio rendition is the one paired",
          probe.variants[0].audio_url == "https://cdn.test/media/audio/en.m3u8",
          probe.variants[0].audio_url)
    check("a variant naming an audio group is marked for muxing",
          probe.variants[0].needs_audio is True)

    absolute = "\n".join(["#EXTM3U",
                          "#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=854x480",
                          "https://other.cdn/abs/480.m3u8"])
    check("an absolute stream URL is left alone",
          mediatools.parse(absolute, "https://cdn.test/a/master.m3u8").variants[0].url
          == "https://other.cdn/abs/480.m3u8")

    segments = "\n".join(["#EXTM3U", "#EXT-X-TARGETDURATION:10", "#EXTINF:9.0,", "s1.ts",
                          "#EXT-X-ENDLIST"])
    media_only = mediatools.parse(segments, "https://cdn.test/v/720.m3u8")
    check("a media playlist is itself one variant",
          len(media_only.variants) == 1 and media_only.variants[0].url.endswith("720.m3u8"))

    mpd = (
        '<?xml version="1.0"?>'
        '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">'
        '<Period><AdaptationSet contentType="video" mimeType="video/mp4" frameRate="30000/1001">'
        '<Representation id="v1" bandwidth="800000" width="854" height="480">'
        "<BaseURL>video/480.mp4</BaseURL></Representation>"
        '<Representation id="v2" bandwidth="3000000" width="1920" height="1080">'
        "<BaseURL>video/1080.mp4</BaseURL></Representation></AdaptationSet>"
        '<AdaptationSet contentType="audio" mimeType="audio/mp4" lang="en">'
        '<Representation id="a1" bandwidth="128000"><BaseURL>audio/lo.m4a</BaseURL></Representation>'
        '<Representation id="a2" bandwidth="256000"><BaseURL>audio/hi.m4a</BaseURL></Representation>'
        "</AdaptationSet></Period></MPD>"
    )
    dash = mediatools.parse(mpd, "https://cdn.test/dash/manifest.mpd", "application/dash+xml")
    check("MPD yields the video representations", len(dash.variants) == 2, str(dash.as_dict()))
    check("DASH video is always paired with audio to mux",
          all(v.needs_audio for v in dash.variants))
    check("the best audio representation wins",
          dash.variants[0].audio_url == "https://cdn.test/dash/audio/hi.m4a",
          dash.variants[0].audio_url)
    check("a fractional frame rate is read",
          round(dash.variants[0].frame_rate or 0, 2) == 29.97)
    check("a live MPD says so rather than pretending",
          mediatools.parse(mpd.replace('type="static"', 'type="dynamic"'),
                           "https://cdn.test/m.mpd", "application/dash+xml").unsupported == "live stream")

    check("content type beats the URL when they disagree",
          mediatools.kind_for("https://x/stream?id=9", "application/vnd.apple.mpegurl") == "hls")
    check("a URL alone is enough when the type is missing",
          mediatools.kind_for("https://x/a.mpd") == "dash")
    check("a web page is not media", mediatools.kind_for("https://x/p.html", "text/html") == "unknown")
    check("a manifest is recognised from its body when the type lies",
          mediatools.parse("#EXTM3U\n#EXTINF:1,\ns.ts", "https://x/weird", "text/plain").kind == "hls")
    check("filenames are built from the title and height",
          mediatools.suggested_name("https://x/master.m3u8", "My Video", 1080) == "My Video_1080p.mp4")
    check("filenames drop characters a filesystem would refuse",
          "/" not in mediatools.suggested_name("https://x/m.m3u8", "a/b:c", None))

    print("\nunit: rules validation")
    from aria_download_manager.rules import RuleEngine

    engine = RuleEngine.__new__(RuleEngine)  # validate() needs no collaborators
    good = {"name": "r", "when": {"speed_below": 100, "for_seconds": 3}, "action": "pause_resume"}
    check("valid rule passes", engine.validate(good) == [], str(engine.validate(good)))
    check("unknown action rejected",
          any("unknown action" in p for p in engine.validate({**good, "action": "explode"})))
    check("nameless rule rejected",
          any("name" in p for p in engine.validate({**good, "name": ""})))
    check("condition-less rule rejected",
          any("at least one" in p for p in engine.validate({**good, "when": {}})))
    check("set_option without options rejected",
          any("set_option" in p for p in engine.validate({**good, "action": "set_option"})))
    check("bad regex rejected",
          any("regex" in p for p in engine.validate(
              {**good, "when": {**good["when"], "name_matches": "("}})))


# --------------------------------------------------------------------------
# end-to-end
# --------------------------------------------------------------------------
async def test_e2e(tmp_dir: Path) -> None:
    rpc_port = free_port()
    httpd, fake = serve(rpc_port, secret="test-secret")

    config_path = tmp_dir / "config.yaml"
    config_path.write_text(yaml.safe_dump({
        "server": {"socket": str(tmp_dir / "manager.sock")},
        "poll_interval": 0.5,
        "aria2": {
            "managed": False,
            "rpc": {"host": "127.0.0.1", "port": rpc_port, "secret": "test-secret"},
        },
        "history": {"enabled": True, "file": str(tmp_dir / "history.json")},
        "rules_enabled": True,
        "rules": [{
            "name": "stall-recovery",
            "enabled": True,
            "when": {"statuses": ["active"], "speed_below": 51200,
                     "for_seconds": 2, "min_age_seconds": 0},
            "action": "pause_resume",
            "resume_after_seconds": 0.5,
            "cooldown_seconds": 30,
            "max_triggers": 5,
        }],
    }))

    cfg = Config(config_path)
    app = create_app(cfg)
    server = ManagerRunner(app)
    task = asyncio.create_task(server.serve())
    base = ""

    async with IPCSession(cfg.get("server.socket")) as http:
        async def get(path):
            async with http.get(base + path) as res:
                return res.status, await res.json()

        async def post(path, body=None):
            async with http.post(base + path, json=body) as res:
                return res.status, await res.json()

        # --- startup
        print("\ne2e: startup")
        up = await wait_for(lambda: server.started, 15)
        check("manager starts and opens its socket", up)
        if not up:
            return

        status, ping = await get("/api/intake/ping")
        check("GET /api/intake/ping", status == 200 and ping.get("ok"))

        ready = await wait_for(lambda: _state_has_downloads(http, base), 10)
        check("state stream picks up the fake downloads", ready)

        status, state = await get("/api/state")
        names = {d["name"] for d in state["downloads"]}
        check("aria2 version detected", state["aria2"]["version"].endswith("-fake"),
              state["aria2"].get("version"))
        check("seeded downloads visible", {"big.iso", "movie.mkv", "queued.zip"} <= names, str(names))
        # The very first snapshot can land before the fake has transferred a
        # single byte, so poll until progress shows up.
        check("normalisation computes progress/eta",
              await wait_for(lambda: _download_progressing(http, base, "movie.mkv"), 8))
        check("queue position exposed",
              any(d.get("queuePosition") == 0 for d in state["downloads"] if d["status"] == "waiting"))

        status, before = await get("/api/config")
        check("config is readable", status == 200 and "aria2" in before)

        # --- adding
        print("\ne2e: adding downloads")
        status, added = await post("/api/downloads", {
            "uris": ["https://example.invalid/one.zip", "https://example.invalid/two.zip"],
            "options": {"dir": str(tmp_dir), "split": 4, "header": ["X-Test: 1"]},
        })
        check("POST /api/downloads adds each URL separately",
              status == 200 and len(added["gids"]) == 2, json.dumps(added))
        new_gid = added["gids"][0]
        check("options reached aria2",
              fake.downloads[new_gid].options.get("split") == "4",
              str(fake.downloads[new_gid].options))

        status, mirrored = await post("/api/downloads", {
            "uris": ["https://a.invalid/f.iso", "https://b.invalid/f.iso"],
            "mirrors": True,
        })
        check("mirrors mode makes one download", status == 200 and len(mirrored["gids"]) == 1)

        status, paused_add = await post("/api/downloads", {
            "url": "https://example.invalid/later.bin", "paused": True})
        check("paused add lands paused",
              status == 200 and fake.downloads[paused_add["gids"][0]].status == "paused")

        status, bad = await post("/api/downloads", {"uris": []})
        check("empty add is rejected with 400", status == 400)

        torrent = base64.b64encode(b"d8:announce3:foo4:infod4:name4:teste").decode()
        status, tor = await post("/api/downloads/file", {"data": torrent, "kind": "torrent"})
        check("POST /api/downloads/file accepts a base64 torrent", status == 200 and tor["gids"])

        status, badb64 = await post("/api/downloads/file", {"data": "!!!not base64!!!"})
        check("invalid base64 is rejected with 400", status == 400)

        # --- per-download commands
        print("\ne2e: per-download commands")
        target = next(d for d in state["downloads"] if d["name"] == "movie.mkv")["gid"]
        status, _ = await post(f"/api/download/{target}/pause")
        check("pause works", status == 200 and fake.downloads[target].status == "paused")
        status, _ = await post(f"/api/download/{target}/resume")
        # Real aria2 (and now the fake) moves an unpaused download to *waiting*;
        # its scheduler promotes it on the next tick.
        check("resume works",
              status == 200
              and await wait_for(lambda: fake.downloads[target].status == "active", 5),
              fake.downloads[target].status)

        await wait_for(lambda: fake.downloads[target].status == "active", 5)
        status, detail = await get(f"/api/download/{target}")
        check("detail returns status/files/servers", status == 200
              and detail["status"]["gid"] == target
              and len(detail["files"]) == 1
              and len(detail["servers"]) == 1,
              f"{status} files={len(detail.get('files', []))} servers={len(detail.get('servers', []))}")
        check("detail returns a piece map", len(detail["pieceMap"]) > 0)
        check("detail lists live connections",
              bool(detail["servers"]) and len(detail["servers"][0]["servers"]) == 2)

        status, applied = await post(f"/api/download/{target}/options",
                                     {"options": {"max-download-limit": "1M"}})
        check("per-download options apply",
              status == 200 and fake.downloads[target].options["max-download-limit"] == "1M")

        status, sel = await post(f"/api/download/{target}/select", {"indices": [1]})
        check("file selection applies",
              status == 200 and fake.downloads[target].options["select-file"] == "1")

        queued = next(d for d in state["downloads"] if d["status"] == "waiting")["gid"]
        status, pos = await post(f"/api/download/{queued}/position", {"pos": 0, "how": "POS_SET"})
        check("queue reposition works", status == 200 and pos["ok"])
        status, badpos = await post(f"/api/download/{queued}/position", {"pos": 0, "how": "NOPE"})
        check("bad reposition rejected with 400", status == 400)

        # --- global commands
        print("\ne2e: global commands")
        status, _ = await post("/api/global/pause-all")
        check("pause all pauses everything", status == 200
              and all(d.status != "active" for d in fake.downloads.values()))
        status, _ = await post("/api/global/resume-all")
        check("resume all resumes", status == 200 and await wait_for(
            lambda: any(d.status == "active" for d in fake.downloads.values()), 5),
              str({d.name: d.status for d in fake.downloads.values()}))

        status, opts = await get("/api/global/options")
        check("GET /api/global/options", status == 200 and "max-concurrent-downloads" in opts)
        status, saved = await post("/api/global/options",
                                   {"options": {"max-concurrent-downloads": "9"}})
        check("global options apply to aria2",
              status == 200 and fake.global_options["max-concurrent-downloads"] == "9")
        persisted = yaml.safe_load(config_path.read_text())
        check("global options persist to config.yaml",
              persisted["aria2"]["options"]["max-concurrent-downloads"] == "9",
              json.dumps(persisted.get("aria2", {})))

        # --- rules API
        print("\ne2e: rules API")
        status, rules = await get("/api/rules")
        check("GET /api/rules lists rules and actions",
              status == 200 and rules["rules"][0]["name"] == "stall-recovery"
              and "pause_resume" in rules["actions"])
        status, toggled = await post("/api/rules/stall-recovery/toggle", {"enabled": False})
        check("rule toggle off", status == 200 and toggled["rule"]["enabled"] is False)
        status, toggled = await post("/api/rules/stall-recovery/toggle", {"enabled": True})
        check("rule toggle on", status == 200 and toggled["rule"]["enabled"] is True)
        status, missing = await post("/api/rules/nope/toggle", {"enabled": True})
        check("unknown rule toggle is 404", status == 404)
        status, rejected = await post("/api/rules", {"rules": [{"name": "x", "action": "boom", "when": {}}]})
        check("invalid rule set is rejected with 400", status == 400,
              json.dumps(rejected)[:120])

        # --- live stream
        print("\ne2e: live stream")
        reader, writer = await asyncio.open_unix_connection(cfg.get("server.socket"),
                                                            limit=64 * 1024 * 1024)
        writer.write(b'{"id": 1, "method": "SUBSCRIBE"}\n')
        await writer.drain()
        kinds: list[str] = []
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline and kinds.count("state") < 2:
            with contextlib.suppress(asyncio.TimeoutError):
                message = json.loads(await asyncio.wait_for(reader.readline(), 2))
                kinds.append(message.get("event") or f"reply:{message.get('id')}")
        writer.close()
        check("the stream pushes repeated state frames", kinds.count("state") >= 2, str(kinds))
        check("the stream sends the event backlog", "backlog" in kinds)

        # --- THE watchdog: speed below X for N seconds -> pause + resume
        print("\ne2e: stall-recovery rule (the custom download action)")
        stalling = next(d for d in fake.downloads.values() if d.name == "big.iso")
        healthy = next(d for d in fake.downloads.values() if d.name == "movie.mkv")
        before_pauses = stalling.pause_count
        # Baseline taken here: earlier tests paused this one deliberately.
        healthy_pauses_before = healthy.pause_count
        fired = await wait_for(lambda: stalling.pause_count > before_pauses, 20)
        check("rule paused the stalled download", fired,
              f"pause_count={stalling.pause_count}, speed={stalling.speed}")
        resumed = await wait_for(lambda: stalling.resume_count >= stalling.pause_count, 10)
        check("rule resumed it again", resumed,
              f"pause={stalling.pause_count} resume={stalling.resume_count}")
        check("download is running after recovery", stalling.status == "active", stalling.status)

        # The action logs once it has finished, which now includes reclaiming the
        # concurrency slot, so wait for the entry rather than assuming it is there.
        await wait_for(lambda: _log_has_level(http, base, "rule"), 15)
        status, log = await get("/api/log")
        rule_events = [e for e in log["events"] if e["level"] == "rule"]
        check("trigger is written to the event log", bool(rule_events),
              json.dumps(log["events"][:3]))
        check("trigger names the rule and action",
              bool(rule_events) and rule_events[0].get("rule") == "stall-recovery"
              and rule_events[0].get("action") == "pause_resume")
        check("trigger list is exposed for the UI", bool(log["triggers"]))

        check("rule left the healthy download alone",
              healthy.pause_count == healthy_pauses_before,
              f"pause_count went {healthy_pauses_before} -> {healthy.pause_count}")

        # --- restart action
        print("\ne2e: restart action / retry endpoint")
        retry_target = next(d for d in fake.downloads.values() if d.name == "one.zip")
        status, retried = await post(f"/api/download/{retry_target.gid}/retry")
        check("retry re-adds the download", status == 200 and "re-added" in retried["detail"],
              json.dumps(retried))

        # --- removal
        print("\ne2e: removal and purge")
        victim = next(d for d in fake.downloads.values() if d.name == "two.zip")
        async with http.delete(base + f"/api/download/{victim.gid}?force=true&purge=true") as res:
            removed_ok = res.status == 200
        check("DELETE removes a download", removed_ok and victim.gid not in fake.downloads)
        status, _ = await post("/api/global/purge")
        check("purge clears finished results", status == 200
              and not any(d.status in ("complete", "error", "removed") for d in fake.downloads.values()))

        # --- browser intake
        print("\ne2e: browser intake")
        status, ping = await get("/api/intake/ping")
        check("intake ping reports readiness", status == 200 and ping["ok"] and ping["aria2"])

        status, us = await post("/api/intake/add", {
            "url": "https://example.invalid/protected/file.iso?token=abc",
            "filename": "../../escape.iso",
            "referer": "https://example.invalid/page",
            "cookie": "session=xyz; theme=dark",
            "userAgent": "TestUA/1.0",
            "headers": {"Authorization": "Bearer t"},
            "dir": str(tmp_dir),
        })
        check("intake add succeeds", status == 200 and us["ok"] and us["count"] == 1)
        got = fake.downloads[us["gids"][0]].options
        check("referer forwarded", got.get("referer") == "https://example.invalid/page")
        check("user-agent forwarded", got.get("user-agent") == "TestUA/1.0")
        check("cookie became a Cookie header", "Cookie: session=xyz; theme=dark" in got.get("header", []))
        check("extra headers forwarded", "Authorization: Bearer t" in got.get("header", []))
        check("filename is basename-only (no path escape)", got.get("out") == "escape.iso",
              str(got.get("out")))
        check("dir forwarded", got.get("dir") == str(tmp_dir))

        status, multi = await post("/api/intake/add", {
            "urls": ["https://example.invalid/a.zip", "https://example.invalid/b.zip"]})
        check("intake batch add", status == 200 and multi["count"] == 2)

        status, nourl = await post("/api/intake/add", {})
        check("intake add without a url is 400", status == 400)

        # --- finished-download history (survives restarts and purges)
        print("\ne2e: finished-download history")
        history_file = tmp_dir / "history.json"
        recorded = await wait_for(lambda: _history_has(http, base), 20)
        check("finished downloads are recorded", recorded)
        status, hist = await get("/api/history?limit=50")
        check("GET /api/history returns entries and a summary",
              status == 200 and hist["entries"] and "count" in hist["summary"])
        entry = hist["entries"][0]
        check("entry keeps name, size and status",
              entry["name"] and entry["status"] in ("complete", "error", "removed")
              and entry["total"] >= 0, json.dumps(entry)[:160])
        check("entry keeps the URL so it can be queued again", bool(entry.get("url")),
              json.dumps(entry)[:160])
        check("history is written to disk", history_file.is_file(), str(history_file))

        # Purging aria2's own results must not erase our record.
        before = len(hist["entries"])
        await post("/api/global/purge")
        await asyncio.sleep(1.5)
        status, after_purge = await get("/api/history?limit=50")
        check("history survives aria2's purgeDownloadResult",
              len(after_purge["entries"]) >= before,
              f"{before} -> {len(after_purge['entries'])}")

        readd_key = next((e["key"] for e in after_purge["entries"] if e.get("url")), None)
        if readd_key:
            status, readded = await post("/api/history/readd", {"key": readd_key})
            check("a past download can be queued again from history",
                  status == 200 and readded.get("gid"), f"{status} {json.dumps(readded)[:120]}")

        status, gone = await post("/api/history-clear")
        check("history can be cleared", status == 200 and gone["removed"] >= 1, str(gone))

        # --- error propagation from aria2
        print("\ne2e: error handling")
        # aria2 answers application errors with HTTP 400 plus a JSON-RPC error
        # body; the client must read the body, not just the status, or every
        # "already removed" looks like a dead daemon.
        async with http.post(base + "/api/download/deadbeef/pause") as res:
            status, err = res.status, await res.json()
        check("aria2 application error surfaces as 502 with its real message",
              status == 502 and "No such download" in str(err.get("error")), json.dumps(err))
        check("an aria2 error is NOT reported as 'not running'",
              "not running" not in str(err.get("error")).lower(), json.dumps(err))

        async with http.delete(base + "/api/download/deadbeefdeadbeef?force=true&purge=true") as res:
            del_status = res.status
            del_body = await res.json()
        check("deleting an already-gone download is a clean success",
              del_status == 200 and del_body.get("ok") is True,
              f"{del_status} {json.dumps(del_body)}")

        status, cfg_out = await get("/api/config")
        check("GET /api/config hides the RPC secret", status == 200
              and cfg_out["aria2"]["rpc"]["secret"] == "***")

        status, state = await get("/api/state")
        check("aria2 status reports unmanaged mode", status == 200 and state["aria2"]["managed"] is False)

    server.stop()
    with contextlib.suppress(asyncio.TimeoutError):
        await asyncio.wait_for(task, timeout=10)
    httpd.shutdown()
    fake.stop()


async def test_managed(tmp_dir: Path) -> None:
    """Managed mode: spawn a child, notice a crash, restart it, shut it down."""
    import os
    import signal

    print("\ne2e: managed aria2c process")
    rpc_port = free_port()
    shim = Path(__file__).resolve().parent / "fake_aria2c"

    config_path = tmp_dir / "managed.yaml"
    config_path.write_text(yaml.safe_dump({
        "server": {"socket": str(tmp_dir / "manager.sock")},
        "poll_interval": 0.5,
        "aria2": {
            "managed": True,
            "binary": str(shim),
            "restart_on_exit": True,
            "startup_timeout": 15.0,
            "rpc": {"host": "127.0.0.1", "port": rpc_port, "secret": "managed-secret"},
            "session_file": str(tmp_dir / "aria2.session"),
            "log_file": str(tmp_dir / "aria2.log"),
            "options": {"dir": str(tmp_dir / "dl")},
        },
        "rules_enabled": False,
        "rules": [],
    }))

    cfg = Config(config_path)
    app = create_app(cfg)
    server = ManagerRunner(app)
    task = asyncio.create_task(server.serve())
    base = ""

    async with IPCSession(cfg.get("server.socket")) as http:
        async def status() -> dict:
            async with http.get(base + "/api/state") as res:
                return (await res.json())["aria2"]

        await wait_for(lambda: server.started, 15)
        started = await wait_for(lambda: _running(http, base), 20)
        check("manager spawns aria2c and reaches its RPC", started)
        if not started:
            server.stop()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(task, timeout=10)
            return

        info = await status()
        first_pid = info["pid"]
        check("child pid is reported", isinstance(first_pid, int) and first_pid > 0, str(first_pid))
        check("version comes from the child", info["version"].endswith("-fake"), info["version"])
        check("mode is reported as managed", info["managed"] is True)
        check("download dir was created", (tmp_dir / "dl").is_dir())
        check("state flows through the managed child",
              await wait_for(lambda: _state_has_downloads(http, base), 10))

        # Kill it the hard way and confirm the supervisor brings it back.
        os.kill(first_pid, signal.SIGKILL)
        restarted = await wait_for(
            lambda: _pid_changed(http, base, first_pid), 25, interval=0.5)
        check("supervisor restarts aria2c after a crash", restarted)
        info = await status()
        check("restart counter incremented", info["restarts"] >= 1, str(info["restarts"]))
        check("crash was logged", await _log_contains(http, base, "exited with code"))

        # Explicit restart via the API.
        pid_before = info["pid"]
        async with http.post(base + "/api/aria2/restart") as res:
            check("POST /api/aria2/restart succeeds", res.status == 200)
        replaced = await wait_for(lambda: _pid_changed(http, base, pid_before), 10)
        info = await status()
        check("explicit restart replaces the process", replaced, str(info["pid"]))
        final_pid = info["pid"]

    server.stop()
    with contextlib.suppress(asyncio.TimeoutError):
        await asyncio.wait_for(task, timeout=15)
    gone = await wait_for(lambda: not _pid_alive(final_pid), 12, interval=0.4)
    check("child is stopped when the manager exits", gone, f"pid {final_pid} still alive")


def test_rule_timing() -> None:
    """Regressions around *when* a rule is allowed to fire."""
    print("\nunit: rule timing and speed source")
    from aria_download_manager.rules import RuleEngine, Tracker

    engine = RuleEngine.__new__(RuleEngine)
    engine.cfg = _FakeCfg()

    when = {"statuses": ["active"], "speed_below": 256000,
            "for_seconds": 1, "min_age_seconds": 8}
    now = 1000.0

    def dl(**kw):
        base = {"gid": "g", "status": "active", "downloadSpeed": 0, "measuredSpeed": None,
                "connections": 4, "progress": 10.0, "total": 1 << 30, "isTorrent": False,
                "name": "f.bin"}
        base.update(kw)
        return base

    # A download can sit queued for ages; its grace period must start when it
    # actually begins transferring, not when it first appeared in the queue.
    queued_long_ago = Tracker(first_seen=now - 600, active_since=now - 1)
    check("a just-started download is inside its grace period even after a long wait",
          engine._matches(when, dl(), queued_long_ago, now) is False)
    running_a_while = Tracker(first_seen=now - 600, active_since=now - 30)
    check("a download that has been running past the grace period is judged",
          engine._matches(when, dl(), running_a_while, now) is True)

    # A non-active download is never a candidate.
    check("a queued download is never matched",
          engine._matches(when, dl(status="waiting"), running_a_while, now) is False)
    check("a paused download is never matched",
          engine._matches(when, dl(status="paused"), running_a_while, now) is False)

    # Speed source: aria2's average lags, the measured delta does not.
    lagging = dl(downloadSpeed=5_000_000, measuredSpeed=0)
    check("the measured delta is used by default, so a stall is seen at once",
          engine._matches(when, lagging, running_a_while, now) is True)
    check("speed_source: aria2 opts back into the smoothed average",
          engine._matches({**when, "speed_source": "aria2"}, lagging, running_a_while, now)
          is False)
    check("measured speed is what gets reported for a trigger",
          engine.speed_of(lagging, when) == 0)
    check("aria2's figure is reported when asked for",
          engine.speed_of(lagging, {"speed_source": "aria2"}) == 5_000_000)
    check("a missing measurement falls back to aria2's number",
          engine.speed_of(dl(downloadSpeed=1234, measuredSpeed=None), when) == 1234)


class _FakeCfg:
    def __init__(self, **values):
        self.values = values

    def get(self, key, default=None):
        return self.values.get(key, default)


def test_speed_sources() -> None:
    """aria2 / measured / hybrid must each behave as advertised."""
    print("\nunit: speed source choices")
    from aria_download_manager.rules import RuleEngine

    engine = RuleEngine.__new__(RuleEngine)
    engine.cfg = _FakeCfg()
    lagging = {"downloadSpeed": 5_000_000, "measuredSpeed": 0}
    fresh = {"downloadSpeed": 5_000_000, "measuredSpeed": None}

    check("hybrid is the default", engine.speed_source() == "hybrid")
    check("an unknown value falls back to hybrid",
          engine.speed_source({"speed_source": "nonsense"}) == "hybrid")

    check("aria2 source reports aria2's average",
          engine.speed_of(lagging, {"speed_source": "aria2"}) == 5_000_000)
    check("measured source reports the write speed",
          engine.speed_of(lagging, {"speed_source": "measured"}) == 0)
    check("measured source reports unknown when there is no sample yet",
          engine.speed_of(fresh, {"speed_source": "measured"}) is None)
    check("hybrid prefers the measurement",
          engine.speed_of(lagging, {"speed_source": "hybrid"}) == 0)
    check("hybrid falls back to aria2 without a measurement",
          engine.speed_of(fresh, {"speed_source": "hybrid"}) == 5_000_000)

    engine.cfg = _FakeCfg(rules_speed_source="aria2")
    check("the global setting applies when a rule says nothing",
          engine.speed_of(lagging) == 5_000_000)
    check("a rule overrides the global setting",
          engine.speed_of(lagging, {"speed_source": "measured"}) == 0)

    # A rule must not fire on a speed it cannot measure.
    from aria_download_manager.rules import Tracker
    engine.cfg = _FakeCfg()
    tracker = Tracker(first_seen=0.0, active_since=1.0)
    row = {"gid": "g", "status": "active", "connections": 4, "progress": 5.0,
           "total": 1 << 30, "isTorrent": False, "name": "f", **fresh}
    strict = {"statuses": ["active"], "speed_below": 1000,
              "speed_source": "measured", "min_age_seconds": 0}
    check("a rule does not fire while the measured speed is unknown",
          engine._matches(strict, row, tracker, 100.0) is False)


def test_idle_backoff():
    """The poller only slows down when nothing is live and nobody is watching."""
    print("\nunit: idle poll backoff")
    from aria_download_manager.state import Poller, Store

    store = Store()
    poller = Poller(None, store, None, None, interval=1.0, idle_interval=5.0)

    busy = {"counts": {"active": 1, "waiting": 0, "paused": 0}}
    quiet = {"counts": {"active": 0, "waiting": 0, "paused": 0}}
    queued = {"counts": {"active": 0, "waiting": 2, "paused": 0}}

    check("a live download keeps the fast tick", poller._is_idle(busy) is False)
    check("a queued download keeps the fast tick", poller._is_idle(queued) is False)
    check("nothing live and nobody watching goes idle", poller._is_idle(quiet) is True)

    queue = store.subscribe()
    check("a connected UI keeps the fast tick", poller._is_idle(quiet) is False)
    store.unsubscribe(queue)
    check("dropping the last UI allows idling again", poller._is_idle(quiet) is True)

    poller._idle = True
    check("idle uses the slower interval", poller.current_interval == 5.0)
    poller.poke()
    check("any command drops back to the fast tick immediately",
          poller._idle is False and poller.current_interval == 1.0)


def test_measured_speed() -> None:
    print("\nunit: measured speed")
    from aria_download_manager.state import Poller

    poller = Poller.__new__(Poller)
    poller._progress = {}

    def sample(completed, at):
        row = {"gid": "a", "completed": completed}
        poller._measure_speed(row, at)
        return row["measuredSpeed"]

    check("no measurement on the first sighting", sample(1_000_000, 100.0) is None)
    check("no measurement until the window is wide enough",
          sample(1_500_000, 100.5) is None)
    check("speed is the byte delta across the window",
          sample(3_000_000, 102.0) == 1_000_000, "expected 1 MiB/s")

    # A download that is merely slow completes data in lumps; one empty tick in
    # the middle of the window must not read as a stall.
    poller._progress.clear()
    sample(0, 200.0); sample(0, 201.0)
    lumpy = sample(600_000, 202.0)
    check("a lumpy but healthy download is not measured as stalled",
          lumpy and lumpy > 250_000, str(lumpy))

    poller._progress.clear()
    sample(1_000_000, 300.0); sample(1_000_000, 301.5)
    check("a genuinely stalled download measures zero even if aria2 claims speed",
          sample(1_000_000, 303.0) == 0)

    poller._progress.clear()
    sample(1_000_000, 400.0)
    check("a restarted file reports no measurement rather than a negative speed",
          sample(500_000, 402.0) is None)


def test_history(tmp_dir: Path) -> None:
    """Clearing history must stick, even though aria2 keeps listing the downloads."""
    print("\nunit: history")
    from aria_download_manager.history import History

    tmp_dir.mkdir(parents=True, exist_ok=True)
    path = tmp_dir / "history.json"
    cfg = Config(tmp_dir / "cfg.yaml") if (tmp_dir / "cfg.yaml").is_file() else None
    if cfg is None:
        (tmp_dir / "cfg.yaml").write_text(yaml.safe_dump(
            {"history": {"enabled": True, "file": str(path)}}))
        cfg = Config(tmp_dir / "cfg.yaml")

    history = History(cfg)
    finished = {"downloads": [
        {"gid": "g1", "status": "complete", "name": "a.bin", "path": "/dl/a.bin",
         "total": 10, "completed": 10, "firstUri": "http://x/a.bin"},
        {"gid": "g2", "status": "error", "name": "b.bin", "path": "/dl/b.bin",
         "total": 10, "completed": 3, "errorMessage": "boom"},
    ]}
    history.observe(finished)
    check("finished downloads are recorded", len(history.list()) == 2)

    # aria2 still has both in its results, so the next poll re-observes them.
    removed = history.remove("/dl/a.bin")
    history.observe(finished)
    check("a removed entry stays removed across the next poll",
          removed and len(history.list()) == 1, str(history.list()))

    history.observe(finished)
    count = history.clear()
    history.observe(finished)   # the poll that used to undo the clear
    check("clear() removes everything", count >= 1)
    check("cleared history stays empty across the next poll",
          history.list() == [], str(history.list()))

    # Downloading the same file again must record it once more.
    history.observe({"downloads": [
        {"gid": "g3", "status": "active", "name": "a.bin", "path": "/dl/a.bin",
         "total": 10, "completed": 1},
    ]})
    history.observe(finished)
    check("re-downloading a dismissed file records it again",
          any(e["path"] == "/dl/a.bin" for e in history.list()), str(history.list()))

    history.save(force=True)
    reloaded = History(cfg)
    check("tombstones persist across a restart",
          reloaded.summary()["dismissed"] >= 1, str(reloaded.summary()))


def test_timeline(tmp_dir: Path) -> None:
    """Added / finished times are stamped on rows and survive a restart."""
    print("\nunit: timeline")
    from aria_download_manager import timeline as tl

    tmp_dir.mkdir(parents=True, exist_ok=True)
    path = tmp_dir / "timeline.json"
    line = tl.Timeline(path)
    snap = {"downloads": [{"gid": "g1", "status": "active"}, {"gid": "g2", "status": "waiting"}]}
    line.observe(snap)
    added = snap["downloads"][0]["addedAt"]
    check("rows get an added time", added and snap["downloads"][1]["addedAt"])
    check("unfinished rows have no finished time", snap["downloads"][0]["finishedAt"] is None)

    snap = {"downloads": [{"gid": "g1", "status": "complete"}, {"gid": "g2", "status": "waiting"}]}
    line.observe(snap)
    check("the added time does not move", snap["downloads"][0]["addedAt"] == added)
    check("a finished row gets a finished time", snap["downloads"][0]["finishedAt"])

    line.save(force=True)
    again = tl.Timeline(path)
    snap = {"downloads": [{"gid": "g2", "status": "waiting"}]}
    again.observe(snap)
    check("times persist across a restart", again.entries["g1"]["finished"]
          and snap["downloads"][0]["addedAt"] == line.entries["g2"]["added"])

    again.entries["g1"]["seen"] -= tl.FORGET_AFTER + 1
    again.observe(snap)
    check("long-gone gids are forgotten", "g1" not in again.entries)


async def test_slot_preservation(tmp_dir: Path) -> None:
    """With one concurrency slot, a stall fix must not hand the slot away.

    Pausing an active download frees a slot and aria2 immediately promotes the
    next queued item; unpausing puts ours back in the *queue*, not back to
    running. Without the reclaim step the two silently swap places.
    """
    print("\ne2e: a stalled download keeps its slot")
    tmp_dir.mkdir(parents=True, exist_ok=True)
    rpc_port = free_port()
    httpd, fake = serve(rpc_port, secret="slot-secret", seed=False)
    fake.global_options["max-concurrent-downloads"] = "1"

    first = fake.add("FIRST.bin", 4 << 30)
    first.status = "active"
    second = fake.add("SECOND.bin", 4 << 30)
    second.status = "waiting"

    config_path = tmp_dir / "slot.yaml"
    config_path.write_text(yaml.safe_dump({
        "server": {"socket": str(tmp_dir / "manager.sock")},
        "poll_interval": 0.5,
        "aria2": {"managed": False,
                  "rpc": {"host": "127.0.0.1", "port": rpc_port, "secret": "slot-secret"}},
        "history": {"enabled": False},
        "rules_enabled": False, "rules": [],
    }))
    cfg = Config(config_path)
    app = create_app(cfg)
    server = ManagerRunner(app)
    task = asyncio.create_task(server.serve())
    base = ""

    async with IPCSession(cfg.get("server.socket")) as http:
        await wait_for(lambda: server.started, 15)
        engine = app.state.engine

        check("only one download runs to begin with",
              fake.downloads[first.gid].status == "active"
              and fake.downloads[second.gid].status == "waiting")

        detail = await engine._dispatch(
            {"resume_after_seconds": 0.5, "preserve_slot": True},
            "pause_resume",
            {"gid": first.gid, "downloadSpeed": 1000, "name": "FIRST.bin"},
        )
        await asyncio.sleep(1.5)
        check("the stalled download is running again, not queued",
              fake.downloads[first.gid].status == "active",
              f"FIRST={fake.downloads[first.gid].status} detail={detail}")
        check("the queued download did not steal the slot",
              fake.downloads[second.gid].status == "waiting",
              f"SECOND={fake.downloads[second.gid].status}")
        check("only one download is active afterwards",
              sum(1 for d in fake.downloads.values() if d.status == "active") == 1)
        check("the action reports what it did with the slot",
              "slot" in detail, detail)

        # Opting out must restore the old (aria2-native) behaviour.
        detail = await engine._dispatch(
            {"resume_after_seconds": 0.5, "preserve_slot": False},
            "pause_resume",
            {"gid": first.gid, "downloadSpeed": 1000, "name": "FIRST.bin"},
        )
        await asyncio.sleep(1.5)
        check("preserve_slot: false leaves aria2's own behaviour alone",
              fake.downloads[second.gid].status == "active"
              and fake.downloads[first.gid].status == "waiting",
              f"FIRST={fake.downloads[first.gid].status} SECOND={fake.downloads[second.gid].status}")

    server.stop()
    with contextlib.suppress(asyncio.TimeoutError):
        await asyncio.wait_for(task, timeout=10)
    httpd.shutdown()
    fake.stop()


async def test_history_clear_purges(tmp_dir: Path) -> None:
    """Clearing history must also drop aria2's finished results from the list."""
    print("\ne2e: clearing history empties the finished list too")
    tmp_dir.mkdir(parents=True, exist_ok=True)
    rpc_port = free_port()
    httpd, fake = serve(rpc_port, secret="hist-secret", seed=False)
    done = fake.add("finished.bin", 1024)
    done.status = "complete"
    done.completed = 1024
    failed = fake.add("broken.bin", 1024)
    failed.status = "error"
    failed.error_message = "boom"

    config_path = tmp_dir / "hist.yaml"
    config_path.write_text(yaml.safe_dump({
        "server": {"socket": str(tmp_dir / "manager.sock")},
        "poll_interval": 0.4,
        "aria2": {"managed": False,
                  "rpc": {"host": "127.0.0.1", "port": rpc_port, "secret": "hist-secret"}},
        "history": {"enabled": True, "file": str(tmp_dir / "history.json")},
        "rules_enabled": False, "rules": [],
    }))
    cfg = Config(config_path)
    app = create_app(cfg)
    server = ManagerRunner(app)
    task = asyncio.create_task(server.serve())
    base = ""

    async with IPCSession(cfg.get("server.socket")) as http:
        async def get(path):
            async with http.get(base + path) as res:
                return await res.json()

        await wait_for(lambda: server.started, 15)
        recorded = await wait_for(
            lambda: _history_count(http, base, 2), 10)
        check("both finished downloads are recorded", recorded)
        state = await get("/api/state")
        check("and both are still listed by aria2",
              len([d for d in state["downloads"]
                   if d["status"] in ("complete", "error")]) == 2)

        async with http.post(base + "/api/history-clear") as res:
            cleared = await res.json()
        check("clear reports what it removed", cleared["removed"] == 2, json.dumps(cleared))
        check("clear purged aria2's results too", cleared["purgedAria2Results"] is True)

        empty = await wait_for(lambda: _history_count(http, base, 0), 10)
        check("history stays empty", empty)
        gone = await wait_for(lambda: _no_finished_downloads(http, base), 10)
        check("the finished rows disappear from the downloads list as well", gone,
              json.dumps((await get("/api/state"))["downloads"]))

    server.stop()
    with contextlib.suppress(asyncio.TimeoutError):
        await asyncio.wait_for(task, timeout=10)
    httpd.shutdown()
    fake.stop()


def test_download_only_migration(tmp_dir: Path) -> None:
    """A "download-only" saved among aria2's options must never reach aria2c.

    aria2c aborts on an option it does not know, so a config written by a build
    that treated this as an aria2 option would stop it from starting at all.
    """
    print("\nunit: download-only migration")
    from aria_download_manager.supervisor import Aria2Supervisor

    tmp_dir.mkdir(parents=True, exist_ok=True)
    path = tmp_dir / "stray.yaml"
    path.write_text(yaml.safe_dump({
        "aria2": {"managed": True, "options": {"download-only": "true", "dir": str(tmp_dir)}},
    }))
    cfg = Config(path)
    check("the stray option is taken out of aria2's options",
          "download-only" not in cfg.get("aria2.options"), json.dumps(cfg.get("aria2.options")))
    check("and becomes the manager's own setting", cfg.get("torrent.download_only") is True)
    argv = Aria2Supervisor(cfg, None, lambda *a, **k: None).build_argv()
    check("so aria2c is never given it", not any("download-only" in a for a in argv))
    check("and starts with uploads at the floor", "--max-overall-upload-limit=1" in argv, str(argv))
    rewritten = yaml.safe_load(path.read_text())
    check("the config file itself is repaired",
          "download-only" not in rewritten["aria2"]["options"]
          and rewritten["torrent"]["download_only"] is True, json.dumps(rewritten))


def test_rule_download_type() -> None:
    """A rule can be aimed at torrents, at plain downloads, or at both."""
    print("\nunit: rule download type")
    from aria_download_manager.rules import RuleEngine, Tracker

    engine = RuleEngine.__new__(RuleEngine)
    engine.cfg = type("C", (), {"get": lambda self, key, default=None: default})()
    tracker = Tracker(first_seen=0.0)
    torrent = {"status": "active", "isTorrent": True, "connections": 8, "progress": 10.0,
               "total": 100, "name": "a.torrent", "downloadSpeed": 0, "measuredSpeed": 0}
    plain = dict(torrent, isTorrent=False, name="a.bin")

    both = {"statuses": ["active"]}
    check("by default a rule judges either kind",
          engine._matches(both, torrent, tracker, 1e6) and engine._matches(both, plain, tracker, 1e6))

    only_torrents = {"statuses": ["active"], "torrent_only": True}
    check("torrents only skips a plain download",
          engine._matches(only_torrents, torrent, tracker, 1e6)
          and not engine._matches(only_torrents, plain, tracker, 1e6))

    only_plain = {"statuses": ["active"], "http_only": True}
    check("normal downloads only skips a torrent",
          engine._matches(only_plain, plain, tracker, 1e6)
          and not engine._matches(only_plain, torrent, tracker, 1e6))


def test_routing(tmp_dir: Path) -> None:
    """Downloads land in a folder that matches what they are."""
    print("\nunit: sorting by file type")
    from aria_download_manager.routing import Router, torrent_files

    tmp_dir.mkdir(parents=True, exist_ok=True)
    path = tmp_dir / "routing.yaml"
    path.write_text(yaml.safe_dump({
        "aria2": {"options": {"dir": "/dl"}},
        "routing": {"enabled": True},
    }))
    cfg = Config(path)
    router = Router(cfg, None, lambda *a, **k: None)

    check("an archive is recognised", router.category_of("pack.tar.gz") == "archive")
    check("music is recognised", router.category_of("song.FLAC") == "music")
    check("video is recognised", router.category_of("film.mkv") == "video")
    check("an image is recognised", router.category_of("shot.jpeg") == "image")
    check("anything else falls to other", router.category_of("notes.xyz") == "other")

    got = router.apply({}, uris=["https://host/path/film.mkv?token=abc"])
    check("a plain URL goes to its folder", got.get("dir") == "/dl/Video", json.dumps(got))
    got = router.apply({}, uris=["https://host/get?id=9"], )
    check("a URL with no filename is left alone", "dir" not in got, json.dumps(got))
    got = router.apply({"out": "renamed.mp3"}, uris=["https://host/get?id=9"])
    check("the chosen output name decides", got.get("dir") == "/dl/Music", json.dumps(got))
    got = router.apply({"dir": "/elsewhere"}, uris=["https://host/film.mkv"])
    check("a folder chosen by hand always wins", got["dir"] == "/elsewhere")
    got = router.apply({}, uris=["magnet:?xt=urn:btih:abc"])
    check("a magnet is left for its metadata", "dir" not in got, json.dumps(got))
    check("and the add holds it until then",
          router.wants_paused_metadata({}, ["magnet:?xt=urn:btih:abc"]) is True)
    check("but not when the folder was chosen",
          router.wants_paused_metadata({"dir": "/x"}, ["magnet:?xt=urn:btih:abc"]) is False)

    # A .torrent is read here, and the biggest file decides.
    def bencode(value):
        if isinstance(value, int):
            return b"i%de" % value
        if isinstance(value, str):
            value = value.encode()
        if isinstance(value, bytes):
            return b"%d:" % len(value) + value
        if isinstance(value, list):
            return b"l" + b"".join(bencode(v) for v in value) + b"e"
        return b"d" + b"".join(bencode(k) + bencode(v) for k, v in sorted(value.items())) + b"e"

    payload = bencode({"info": {"name": "pack", "piece length": 16384, "pieces": b"",
                                "files": [{"length": 50, "path": ["readme.nfo"]},
                                          {"length": 9000, "path": ["show", "ep1.mkv"]}]}})
    check("a torrent's file list is read", len(torrent_files(payload)) == 2)
    got = router.apply({}, torrent=base64.b64encode(payload).decode())
    check("a torrent goes by its largest file", got.get("dir") == "/dl/Video", json.dumps(got))
    check("an unreadable torrent does not break the add",
          "dir" not in router.apply({}, torrent=base64.b64encode(b"not a torrent").decode()),
          "it counts as other, which has no folder of its own by default")

    router.save(enabled=True, folders={**router.folders(), "other": "Misc", "video": "/mnt/films"},
                extensions={**router.extensions(), "archive": ["zip", ".7Z "]})
    check("a folder can be absolute", router.folder_for("video") == "/mnt/films")
    check("other can be given a folder too", router.folder_for("other") == "/dl/Misc")
    check("extensions are cleaned up when saved",
          Config(path).get("routing.extensions")["archive"] == ["7z", "zip"],
          json.dumps(Config(path).get("routing.extensions")["archive"]))
    check("sorting is remembered", Config(path).get("routing.enabled") is True)


def test_metadata_rows() -> None:
    """A magnet's metadata fetch is not a download anyone asked for."""
    print("\nunit: magnet metadata rows")
    from aria_download_manager.history import History
    from aria_download_manager.rules import RuleEngine
    from aria_download_manager.state import normalize

    meta = normalize({
        "gid": "m1", "status": "complete", "totalLength": "12361", "completedLength": "12361",
        "infoHash": "abc", "followedBy": ["r1"],
        "bittorrent": {"info": {"name": "[METADATA]Some.Release.mkv"}},
        "files": [{"path": "[METADATA]Some.Release.mkv", "uris": []}],
    })
    check("the metadata fetch is recognised", meta["isMetadata"] is True)
    check("and shown as the torrent it is fetching", meta["name"] == "Some.Release.mkv", meta["name"])

    # What aria2 actually reports once the fetch has finished: a bittorrent
    # object with only the announce list, no info at all, and the prefix left
    # on the file path. Detecting it by the info name alone missed these.
    finished = normalize({
        "gid": "m2", "status": "complete", "totalLength": "12361", "completedLength": "12361",
        "infoHash": "abc", "followedBy": ["r2"],
        "bittorrent": {"announceList": [["http://tracker.example/announce"]]},
        "files": [{"path": "[METADATA][Group] Some Release (Multi-Subs)", "uris": []}],
    })
    check("a finished fetch with no torrent info is still recognised",
          finished["isMetadata"] is True, json.dumps(finished))

    named = normalize({
        "gid": "r3", "status": "complete", "totalLength": "10", "completedLength": "10",
        "bittorrent": {"info": {"name": "[METADATA]weird.but.real"}},
        "files": [{"path": "/home/me/Downloads/[METADATA]weird.but.real", "uris": []}],
    })
    check("a real file that happens to carry the prefix is left alone",
          named["isMetadata"] is False, json.dumps(named))

    real = normalize({
        "gid": "r1", "status": "active", "totalLength": "10", "completedLength": "1",
        "infoHash": "abc", "following": "m1",
        "bittorrent": {"info": {"name": "Some.Release.mkv"}},
        "files": [{"path": "/dl/Some.Release.mkv", "uris": []}],
    })
    check("the torrent itself is not", real["isMetadata"] is False)

    snapshot = {"downloads": [meta, real]}
    history = History.__new__(History)  # no config needed for the filter itself
    history.entries, history.dismissed, history._dirty = {}, {}, False
    history.cfg = type("C", (), {"get": lambda self, key, default=None: True})()
    history.save = lambda force=False: None
    history.observe(snapshot)
    check("history does not record it", list(history.entries) == [], str(history.entries))

    engine = RuleEngine.__new__(RuleEngine)
    engine.tracked = {}
    # rules_enabled False: the tracking is what this checks, not any action.
    engine.cfg = type("C", (), {"get": lambda self, key, default=None: False})()
    asyncio.run(engine.evaluate(snapshot, 1.0))
    check("rules skip it, so a stall rule cannot act on it",
          list(engine.tracked) == ["r1"], str(list(engine.tracked)))


def test_file_plan() -> None:
    """Priority tiers: the highest unfinished tier runs, lower ones wait."""
    print("\nunit: file priority plan")
    from aria_download_manager.priorities import plan

    files = [{"index": str(i), "length": "10", "completedLength": "0"} for i in (1, 2, 3, 4)]
    levels = {"1": 1, "2": 3, "3": 0, "4": 2}
    check("only the top tier is selected first", plan(files, levels) == ([2], True))
    files[1]["completedLength"] = "10"
    check("the next tier joins once it is done", plan(files, levels) == ([2, 4], True))
    files[3]["completedLength"] = "10"
    check("Normal comes last, and nothing waits after it", plan(files, levels) == ([1, 2, 4], False))
    check("'Do not download' is never selected", 3 not in plan(files, levels)[0])


async def test_torrent_controls(tmp_dir: Path) -> None:
    """Download-only and per-file priorities against a fake multi-file torrent."""
    print("\ne2e: download-only torrents and file priorities")
    tmp_dir.mkdir(parents=True, exist_ok=True)
    rpc_port = free_port()
    httpd, fake = serve(rpc_port, secret="bt-secret", seed=False)
    config_path = tmp_dir / "bt.yaml"
    config_path.write_text(yaml.safe_dump({
        "server": {"socket": str(tmp_dir / "manager.sock")},
        "poll_interval": 0.3,
        "aria2": {"managed": False,
                  "rpc": {"host": "127.0.0.1", "port": rpc_port, "secret": "bt-secret"},
                  "options": {"max-overall-upload-limit": "512K"}},
        "history": {"enabled": True, "file": str(tmp_dir / "history.json")},
        "rules_enabled": False, "rules": [],
    }))
    cfg = Config(config_path)
    app = create_app(cfg)
    server = ManagerRunner(app)
    task = asyncio.create_task(server.serve())
    mib = 1024 * 1024

    def torrent(files):
        return base64.b64encode(json.dumps({"name": "pack", "files": files}).encode()).decode()

    async with IPCSession(cfg.get("server.socket")) as http:
        async def get(path):
            async with http.get(path) as res:
                return res.status, await res.json()

        async def post(path, body=None):
            async with http.post(path, json=body) as res:
                return res.status, await res.json()

        await wait_for(lambda: server.started, 15)

        # --- a torrent seeding before download-only is switched on
        _, added = await post("/api/downloads/file", {"data": torrent([mib]), "kind": "torrent"})
        seeder = fake.downloads[added["gids"][0]]
        check("without download-only a finished torrent seeds",
              await wait_for(lambda: seeder.seeding, 5))

        # --- global switch
        status, _ = await post("/api/global/options", {"options": {"download-only": "true"}})
        check("download-only is accepted as a global option", status == 200)
        check("it caps aria2's overall upload at the floor",
              fake.global_options["max-overall-upload-limit"] == "1")
        persisted = yaml.safe_load(config_path.read_text())
        check("it is saved as a manager setting, not an aria2 option",
              persisted["torrent"]["download_only"] is True
              and "download-only" not in persisted["aria2"]["options"], json.dumps(persisted))
        _, opts = await get("/api/global/options")
        check("the settings form reads it back, with the configured upload limit",
              opts["download-only"] == "true" and opts["max-overall-upload-limit"] == "512K",
              json.dumps({k: opts.get(k) for k in ("download-only", "max-overall-upload-limit")}))
        check("a torrent that was already seeding is stopped",
              await wait_for(lambda: seeder.status == "complete", 5), seeder.status)

        _, added = await post("/api/downloads", {"uris": ["magnet:?xt=urn:btih:abc"]})
        opts = fake.downloads[added["gids"][0]].options
        check("new downloads get seed-time=0 and the upload floor",
              opts.get("seed-time") == "0" and opts.get("max-upload-limit") == "1", json.dumps(opts))

        # --- file priorities on a 3-file torrent, slowed so tiers can be seen
        _, added = await post("/api/downloads/file", {
            "data": torrent([mib, mib, mib]), "kind": "torrent", "paused": True,
            "options": {"max-download-limit": str(2 * mib)}})
        gid = added["gids"][0]
        pack = fake.downloads[gid]
        _, detail = await get(f"/api/download/{gid}")
        check("detail reports a priority per file",
              [f["priority"] for f in detail["files"]] == [1, 1, 1], json.dumps(detail["files"]))
        status, _ = await post(f"/api/download/{gid}/files", {"levels": {"1": 1, "2": 3, "3": 0}})
        check("file priorities are accepted", status == 200)
        check("only the Maximum file is selected first", pack.options.get("select-file") == "2",
              pack.options.get("select-file"))
        check("and the torrent is held open for the next tier",
              pack.options.get("seed-ratio") == "0.0" and pack.options.get("seed-time") != "0",
              json.dumps(pack.options))
        status, _ = await post(f"/api/download/{gid}/files", {"levels": {"1": 0, "2": 0, "3": 0}})
        check("choosing no file at all is refused", status == 400)

        await post(f"/api/download/{gid}/resume")
        check("the Normal file follows once Maximum is done",
              await wait_for(lambda: pack.options.get("select-file") == "1,2", 10),
              pack.options.get("select-file"))
        check("download-only applies to the last tier and the torrent ends",
              await wait_for(lambda: pack.status == "complete", 10),
              f"{pack.status} {json.dumps(pack.options)}")
        check("the skipped file was never fetched", pack.file_done[2] == 0, str(pack.file_done))
        check("both wanted files are complete", pack.file_done[:2] == [mib, mib], str(pack.file_done))

        # --- switching it off restores the configured upload limit
        await post("/api/global/options", {"options": {"download-only": "false"}})
        check("switching off restores the configured upload limit",
              fake.global_options["max-overall-upload-limit"] == "512K",
              fake.global_options["max-overall-upload-limit"])

    server.stop()
    with contextlib.suppress(asyncio.TimeoutError):
        await asyncio.wait_for(task, timeout=10)
    httpd.shutdown()
    fake.stop()


async def _history_count(http, base, expected: int) -> bool:
    async with http.get(base + "/api/history") as res:
        data = await res.json()
    return len(data.get("entries", [])) == expected


async def _no_finished_downloads(http, base) -> bool:
    async with http.get(base + "/api/state") as res:
        state = await res.json()
    return not [d for d in state.get("downloads", [])
                if d["status"] in ("complete", "error", "removed")]


async def test_orphan_handling(tmp_dir: Path) -> None:
    """An aria2c that outlives its manager must not break the next run.

    Closing a terminal sends SIGHUP: the manager has to shut down gracefully
    rather than dying on the spot and orphaning aria2c on the RPC port. And if it
    is killed outright, the next run must adopt or reclaim that leftover process.
    """
    import os
    import signal
    import socket as socketlib
    import subprocess

    print("\ne2e: orphaned aria2c handling")
    tmp_dir.mkdir(parents=True, exist_ok=True)
    shim = Path(__file__).resolve().parent / "fake_aria2c"
    rpc_port = free_port()
    session = tmp_dir / "aria2.session"
    session.write_text("# session\n")  # so the shim's cmdline references it

    config_path = tmp_dir / "orphan.yaml"
    config_path.write_text(yaml.safe_dump({
        "server": {"socket": str(tmp_dir / "manager.sock")},
        "poll_interval": 0.5,
        "aria2": {
            "managed": True,
            "binary": str(shim),
            "rpc": {"host": "127.0.0.1", "port": rpc_port, "secret": "orphan-secret"},
            "session_file": str(session),
            "log_file": str(tmp_dir / "aria2.log"),
            "options": {"dir": str(tmp_dir / "dl")},
        },
        "rules_enabled": False, "rules": [],
        "history": {"enabled": False},
    }))
    def manager() -> subprocess.Popen:
        return subprocess.Popen(
            [sys.executable, "-m", "aria_download_manager", "--config", str(config_path)],
            cwd=str(Path(__file__).resolve().parent.parent),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    def shim_pids() -> list[int]:
        found = []
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                cmdline = (entry / "cmdline").read_bytes().decode("utf-8", "replace")
            except OSError:
                continue
            if "fake_aria2c" in cmdline and f"--rpc-listen-port={rpc_port}" in cmdline:
                found.append(int(entry.name))
        return found

    async def running() -> dict | None:
        try:
            res = await IPCSession(str(tmp_dir / "manager.sock")).call("GET", "/api/state", timeout=5)
            return (await res.json())["aria2"]
        except Exception:
            return None

    proc = None
    try:
        # --- SIGHUP must shut everything down cleanly
        proc = manager()
        up = await wait_for(lambda: _status_running(running()), 25)
        check("manager starts its own aria2c", up)
        os.kill(proc.pid, signal.SIGHUP)
        for _ in range(60):
            if proc.poll() is not None:
                break
            await asyncio.sleep(0.5)
        check("SIGHUP (closing the terminal) exits gracefully, not by signal",
              proc.returncode == 0, f"exit code {proc.returncode}")
        await wait_for(lambda: not shim_pids(), 10)
        check("no aria2c is orphaned by SIGHUP", not shim_pids(), str(shim_pids()))

        # --- a rerun after that must simply work
        proc = manager()
        check("the next run starts normally", await wait_for(lambda: _status_running(running()), 25))

        # --- a hard kill DOES orphan it; the following run must recover
        os.kill(proc.pid, signal.SIGKILL)
        proc.wait(timeout=15)
        await asyncio.sleep(1)
        orphans = shim_pids()
        check("SIGKILL leaves aria2c running (nothing can catch that signal)",
              bool(orphans), str(orphans))

        proc = manager()
        adopted = await wait_for(lambda: _status_adopted(running()), 30)
        check("the next run ADOPTS the orphan instead of failing to bind the port", adopted)
        info = await running()
        check("adopted instance is reported as running with its real pid",
              info and info["running"] and info["pid"] in orphans,
              json.dumps({k: info.get(k) for k in ("running", "pid", "adopted")} if info else {}))
        proc.terminate(); proc.wait(timeout=25)
        await wait_for(lambda: not shim_pids(), 12)
        check("stopping the manager also stops the adopted aria2c", not shim_pids(), str(shim_pids()))

        # --- a foreign listener must be reported, never killed
        blocker = socketlib.socket()
        blocker.setsockopt(socketlib.SOL_SOCKET, socketlib.SO_REUSEADDR, 1)
        blocker.bind(("127.0.0.1", rpc_port))
        blocker.listen(1)
        try:
            proc = manager()
            await wait_for(lambda: _status_failed(running()), 20)
            info = await running()
            message = (info or {}).get("last_error", "")
            check("an unrelated listener on the RPC port is reported clearly",
                  info is not None and not info["running"] and "port" in message.lower(),
                  f"running={(info or {}).get('running')} err={message[:120]}")
            check("the foreign listener is left alone", blocker.fileno() != -1)
        finally:
            blocker.close()
    finally:
        if proc and proc.poll() is None:
            proc.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                proc.wait(timeout=15)
        for pid in shim_pids():
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.kill(pid, signal.SIGKILL)


async def _status_failed(coro) -> bool:
    info = await coro
    return bool(info and "running" in info and not info["running"] and info.get("last_error"))


async def _status_running(coro) -> bool:
    info = await coro
    return bool(info and info.get("running"))


async def _status_adopted(coro) -> bool:
    info = await coro
    return bool(info and info.get("running") and info.get("adopted"))


def _pid_alive(pid: int) -> bool:
    import os
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    return True


async def _running(http, base) -> bool:
    async with http.get(base + "/api/state") as res:
        return (await res.json())["aria2"].get("running") is True


async def _pid_changed(http, base, old_pid: int) -> bool:
    async with http.get(base + "/api/state") as res:
        info = (await res.json())["aria2"]
    return bool(info.get("running")) and info.get("pid") not in (None, old_pid)


async def _log_has_level(http, base, level: str) -> bool:
    async with http.get(base + "/api/log") as res:
        data = await res.json()
    return any(e["level"] == level for e in data["events"])


async def _log_contains(http, base, needle: str) -> bool:
    async with http.get(base + "/api/log") as res:
        data = await res.json()
    return any(needle in e["message"] for e in data["events"])


async def _history_has(http, base) -> bool:
    async with http.get(base + "/api/history?limit=5") as res:
        data = await res.json()
    return bool(data.get("entries"))


async def _state_has_downloads(http, base) -> bool:
    async with http.get(base + "/api/state") as res:
        state = await res.json()
    return bool(state.get("downloads"))


async def _download_progressing(http, base, name: str) -> bool:
    async with http.get(base + "/api/state") as res:
        state = await res.json()
    for dl in state.get("downloads", []):
        if dl["name"] == name:
            return dl["progress"] > 0 and dl["eta"] is not None and dl["total"] > 0
    return False


# --------------------------------------------------------------------------
def test_supervisor_argv(tmp_dir: Path) -> None:
    """Managed mode: check the aria2c command line we would spawn."""
    print("\nunit: supervisor argv")
    from aria_download_manager.rpc import Aria2RPC
    from aria_download_manager.supervisor import Aria2Supervisor, SupervisorError

    config_path = tmp_dir / "argv.yaml"
    config_path.write_text(yaml.safe_dump({
        "aria2": {
            "binary": "/bin/sh",  # stand-in so the lookup succeeds
            "rpc": {"host": "127.0.0.1", "port": 6801, "secret": "s3cret"},
            "session_file": str(tmp_dir / "aria2.session"),
            "log_file": str(tmp_dir / "aria2.log"),
            "options": {"dir": str(tmp_dir / "dl"), "split": 8, "continue": True},
            "extra_args": ["--bt-tracker=udp://t.example:1337"],
        },
    }))
    cfg = Config(config_path)
    sup = Aria2Supervisor(cfg, Aria2RPC("127.0.0.1", 6801), lambda *a, **k: None)
    argv = sup.build_argv()
    joined = " ".join(argv)
    check("rpc is enabled", "--enable-rpc=true" in argv)
    check("rpc bound to loopback only", "--rpc-listen-all=false" in argv)
    check("rpc port passed", "--rpc-listen-port=6801" in argv)
    check("secret passed", "--rpc-secret=s3cret" in argv)
    check("session saving enabled", "--save-session-interval=30" in argv)
    check("options rendered as flags", "--split=8" in argv and "--continue=true" in argv)
    check("bools stringified, not Python-cased", "--continue=True" not in joined)
    check("extra_args appended last", argv[-1] == "--bt-tracker=udp://t.example:1337")
    check("download dir created", (tmp_dir / "dl").is_dir())
    check("no input-file flag when there is no session yet", "--input-file" not in joined)

    (tmp_dir / "aria2.session").write_text("# session\n")
    check("input-file added once a session exists",
          any(a.startswith("--input-file=") for a in sup.build_argv()))

    cfg.data["aria2"]["binary"] = "definitely-not-a-real-binary-xyz"
    try:
        sup.build_argv()
        check("missing binary raises a helpful error", False, "no exception raised")
    except SupervisorError as exc:
        check("missing binary raises a helpful error", "not found in PATH" in str(exc), str(exc))


def test_config(tmp_dir: Path) -> None:
    print("\nunit: config")
    path = tmp_dir / "cfg.yaml"
    path.write_text(yaml.safe_dump({
        "server": {"socket": "/tmp/custom.sock"},
        "aria2": {"options": {"split": 32}},
    }))
    cfg = Config(path)
    check("user values win", cfg.get("server.socket") == "/tmp/custom.sock")
    check("defaults fill the gaps", cfg.get("poll_interval") == 1.0)
    check("nested user options merge, not replace",
          cfg.get("aria2.options.split") == "32" and cfg.get("aria2.options.continue") == "true")
    check("paths expanded", not str(cfg.get("aria2.session_file")).startswith("~"))
    check("managed mode generates an RPC secret", len(cfg.get("aria2.rpc.secret")) > 10)

    cfg.rules = [{"name": "only", "enabled": False, "when": {"speed_below": 1}, "action": "log_only"}]
    cfg.save()
    reread = yaml.safe_load(path.read_text())
    check("save() persists rules", reread["rules"][0]["name"] == "only")
    check("save() keeps unrelated user keys", reread["server"]["socket"] == "/tmp/custom.sock")
    check("save() does not write the generated secret",
          "secret" not in json.dumps(reread.get("aria2", {})))


def main() -> int:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="aria-download-manager-test-") as tmp:
        tmp_dir = Path(tmp)
        # Every manager started here opens its IPC socket at the default path;
        # keep that away from a real manager running in this session.
        os.environ["XDG_RUNTIME_DIR"] = tmp
        for name in ("c1", "c2", "c3", "c4", "c6", "c7", "c8", "c9"):
            (tmp_dir / name).mkdir(parents=True, exist_ok=True)
        test_units()
        test_rule_timing()
        test_speed_sources()
        test_measured_speed()
        test_idle_backoff()
        test_history(tmp_dir / "c7")
        test_timeline(tmp_dir / "c7")
        test_file_plan()
        test_metadata_rows()
        test_rule_download_type()
        test_routing(tmp_dir / "c12")
        test_download_only_migration(tmp_dir / "c11")
        test_config(tmp_dir / "c1")
        test_supervisor_argv(tmp_dir / "c2")
        asyncio.run(test_e2e(tmp_dir / "c3"))
        asyncio.run(test_managed(tmp_dir / "c4"))
        asyncio.run(test_slot_preservation(tmp_dir / "c8"))
        asyncio.run(test_history_clear_purges(tmp_dir / "c9"))
        asyncio.run(test_torrent_controls(tmp_dir / "c10"))
        asyncio.run(test_orphan_handling(tmp_dir / "c6"))

    return summary()


if __name__ == "__main__":
    raise SystemExit(main())
