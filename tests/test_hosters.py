"""Tests for the hoster queue: resolvers, sequencing, captcha hand-off.

Run via the main suite (`python3 tests/test_manager.py`) or standalone:

    python3 tests/test_hosters.py
"""

from __future__ import annotations

import asyncio
import json
import sys
import time
from pathlib import Path

import aiohttp
import uvicorn
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from aria2c_manager.config import Config  # noqa: E402
from aria2c_manager.hosters import MediaFireResolver, XFileSharingResolver, build_registry, pick_resolver  # noqa: E402
from aria2c_manager.hosters.base import (  # noqa: E402
    ResolveError,
    filename_from_disposition,
    find_form,
    hidden_inputs,
    host_of,
    safe_name,
)
from tests.fake_aria2 import serve as serve_aria2  # noqa: E402
from tests.fake_hoster import CF_CLEARANCE, EXPECTED_CODE, serve as serve_hoster  # noqa: E402
from tests.harness import check, free_port, wait_for  # noqa: E402


# --------------------------------------------------------------------------
# resolver unit tests
# --------------------------------------------------------------------------
# The exact markup a live MediaFire page served in August 2026: href comes
# BEFORE id, and the attributes span multiple lines.
REAL_MEDIAFIRE_SNIPPET = """
<div class="dl-info"><div class="filename">test-10mb.bin</div></div>
<a class="input popsok"
           aria-label="Download file"
           href="https://download1514.mediafire.com/rbzn08fcusagl_TOKEN/ipnyzofjcwri357/test-10mb.bin"           id="downloadButton"
           rel="nofollow">
"""


def _guard_raises(resolver, html: str) -> bool:
    try:
        resolver._guard(html)
    except ResolveError:
        return True
    return False


def test_units() -> None:
    print("\nunit: hoster helpers")
    check("host_of strips www and port",
          host_of("https://www.mediafire.com:443/file/x/y") == "mediafire.com")
    check("host_of tolerates junk", host_of("not a url") == "")
    check("safe_name reduces a path to a basename",
          safe_name("../../etc/passwd") == "passwd")
    check("safe_name scrubs illegal characters",
          safe_name('we:ird*name?.bin') == "we_ird_name_.bin")
    check("filename_from_disposition reads the quoted form",
          filename_from_disposition('attachment; filename="test-10mb.bin"') == "test-10mb.bin")

    form = find_form(
        '<form><input name="op" value="download1"><input name="id" value="7"></form>'
        '<form><input name="other" value="x"></form>',
        "download1",
    )
    check("find_form picks the form holding the needle", form is not None and 'value="7"' in form)
    fields = hidden_inputs(
        "", '<form><input type="hidden" name="op" value="download2">'
            '<input name="code" value=""><input type="submit" name="go" value="Go"></form>'
    )
    check("hidden_inputs collects fields and drops submits",
          fields == {"op": "download2", "code": ""}, str(fields))

    print("\nunit: mediafire resolver")
    mf = MediaFireResolver()
    check("matches mediafire URLs", mf.matches("https://www.mediafire.com/file/abc/x.bin/file"))
    check("ignores other hosts", not mf.matches("https://kenfiles.com/abc"))
    extracted = mf._extract(REAL_MEDIAFIRE_SNIPPET)
    check("extracts the link from real page markup",
          extracted == "https://download1514.mediafire.com/rbzn08fcusagl_TOKEN/ipnyzofjcwri357/test-10mb.bin",
          str(extracted))
    check("reads the filename from the page", mf._filename(REAL_MEDIAFIRE_SNIPPET) == "test-10mb.bin")
    check("falls back to a bare download-host URL",
          mf._extract('x <a href="https://download99.mediafire.com/tok/key/n.zip">y</a>')
          == "https://download99.mediafire.com/tok/key/n.zip")
    check("returns nothing when there is no link", mf._extract("<html>nope</html>") is None)

    print("\nunit: xfilesharing resolver")
    xfs = XFileSharingResolver()
    check("matches kenfiles", xfs.matches("https://kenfiles.com/abc123"))
    check("extra domains can be added",
          XFileSharingResolver(extra_domains=("clone.example",)).matches("https://clone.example/x"))
    for html, expected in (
        ('<span id="countdown_str">Wait <span id="z" class="seconds">30</span> seconds</span>', 30),
        ('<span id="countdown">45</span>', 45),
        ("var secs = 15;", 15),
        ("<html>no countdown</html>", 0),
    ):
        got = xfs._countdown(html)
        check(f"countdown {expected}s parsed", got == expected, f"got {got}")

    browser = xfs._challenge('<div class="g-recaptcha" data-sitekey="k"></div>', "http://h/")
    check("reCAPTCHA is classed as browser-only", browser and browser["kind"] == "browser")
    digits_html = "".join(
        f'<span style="position:absolute;padding-left:{off}px;padding-top:8px;">{d}</span>'
        for off, d in ((63, "2"), (18, "4"), (95, "1"), (41, "8"))
    )
    digits = xfs._challenge(digits_html, "http://h/")
    check("ordered digits are read straight off the page",
          digits and digits["kind"] == "digits" and digits["code"] == EXPECTED_CODE,
          str(digits))
    code = xfs._challenge('<img src="/captchas/a.jpg"><input name="code">', "http://h/x")
    check("image captcha asks a human for a code",
          code and code["kind"] == "code" and code["image"] == "http://h/captchas/a.jpg", str(code))
    check("no challenge detected when there is none",
          xfs._challenge("<html>plain</html>", "http://h/") is None)

    check("direct link found via id=direct_link",
          xfs._extract_direct('<a id="direct_link" href="http://dl.kenfiles.com/f/a.zip">go</a>',
                              "http://kenfiles.com/x") == "http://dl.kenfiles.com/f/a.zip")
    check("direct link found via a JS redirect",
          xfs._extract_direct("window.location.href = 'http://dl.kenfiles.com/b.rar';",
                              "http://kenfiles.com/x") == "http://dl.kenfiles.com/b.rar")
    check("assets are not mistaken for the download",
          xfs._extract_direct('<link href="http://kenfiles.com/css/style.css">',
                              "http://kenfiles.com/x") is None)

    print("\nunit: real kenfiles page shapes (regressions)")
    # Taken from the live page for
    # https://kenfiles.com/be0ygt35z0bv/16_-_Bolly_Noir.mp3.html (August 2026).
    ken_wait_page = (
        '<html><head><title>Download Bolly Noir mp3 &gt; KenFiles</title></head><body>'
        '<div id="free_dl_countdown" class="form-group text-center pt-2">'
        '<span id="countdowns">Wait <span class="seconds fw-bold text-danger fs-20px">30</span>'
        ' seconds</span> to download</div>'
        '<form name="F1" method="POST" action="">'
        '<input type="hidden" name="op" value="download2">'
        '<input type="hidden" name="id" value="be0ygt35z0bv">'
        '<input type="hidden" name="rand" value="y34advqcnzlwlp2gjbdd">'
        '<input type="hidden" name="referer" value="https://kenfiles.com/be0ygt35z0bv/16_-_Bolly_Noir.mp3.html">'
        '<input type="hidden" name="method_free" value="1">'
        '<input type="hidden" name="method_premium" value="">'
        '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js"></script>'
        '<div class="cf-turnstile" data-sitekey="0x4AAA"></div>'
        '</form>'
        # The literal phrase sits in a JS template on a perfectly healthy page.
        '<script>var msgs = {err: "File not found", ok: "Done"};</script>'
        '<link rel="canonical" href="https://kenfiles.com/be0ygt35z0bv/16_-_Bolly_Noir.mp3.html">'
        '<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1"></script>'
        "</body></html>"
    )
    ken_url = "https://kenfiles.com/be0ygt35z0bv/16_-_Bolly_Noir.mp3.html"

    check("real countdown markup parses as 30s (multi-class, plural id)",
          xfs._countdown(ken_wait_page) == 30, str(xfs._countdown(ken_wait_page)))
    check("Turnstile on the real page is classed browser-only",
          (xfs._challenge(ken_wait_page, ken_url) or {}).get("label") == "Cloudflare Turnstile",
          str(xfs._challenge(ken_wait_page, ken_url)))
    check("the page's own canonical URL is NOT taken as the download link",
          xfs._extract_direct(ken_wait_page, ken_url) is None,
          str(xfs._extract_direct(ken_wait_page, ken_url)))
    dead = None
    try:
        xfs._guard(ken_wait_page)
    except ResolveError as exc:
        dead = str(exc)
    check('"file not found" inside a JS template does not kill the job', dead is None, str(dead))
    check("a genuine not-found message still raises",
          _guard_raises(xfs, '<html><h1>File Not Found</h1></html>'))
    check("an .html page is never treated as a file",
          not xfs._plausible("https://kenfiles.com/x/y.html", ken_url, strict=True))
    check("a sibling download host IS accepted",
          xfs._plausible("https://s01.kenfiles.com/d/abc/16.mp3", ken_url, strict=True))

    print("\nunit: cloudflare detection")
    from aria2c_manager.hosters.base import detect_cloudflare
    check("interstitial detected by title",
          bool(detect_cloudflare("<title>Just a moment...</title>", 503)))
    # Every Cloudflare-fronted site loads this beacon on perfectly normal pages —
    # treating it as a challenge parked every kenfiles job by mistake.
    check("the challenge-platform beacon alone is NOT a challenge",
          detect_cloudflare(
              '<html><title>Download file</title>'
              '<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1"></script>'
              '</html>') is None)
    check("a real interstitial is still detected",
          bool(detect_cloudflare(
              '<title>Just a moment...</title><div class="cf-browser-verification"></div>', 503)))
    check("cf-mitigated header detected",
          bool(detect_cloudflare("<html>ok</html>", 200, {"cf-mitigated": "challenge"})))
    check("a normal page is not flagged",
          detect_cloudflare("<html><a id=downloadButton href=x>dl</a></html>", 200) is None)
    check("turnstile markup on a real page is not an interstitial",
          detect_cloudflare('<div class="cf-turnstile" data-sitekey="k"></div>', 200) is None)

    print("\nunit: registry")
    registry = build_registry(None)
    check("mediafire URL routes to the mediafire resolver",
          pick_resolver("https://mediafire.com/file/a/b/file", registry).name == "mediafire")
    check("kenfiles URL routes to the xfilesharing resolver",
          pick_resolver("https://kenfiles.com/abc", registry).name == "xfilesharing")
    check("anything else falls back to direct",
          pick_resolver("https://example.com/f.zip", registry).name == "direct")

    async def folder_rejected():
        mfr = MediaFireResolver()
        try:
            async with aiohttp.ClientSession() as session:
                await mfr.resolve(session, "https://www.mediafire.com/folder/abc/Public")
        except ResolveError as exc:
            return exc.permanent and "folder" in str(exc).lower()
        return False

    check("mediafire folder links are rejected up front", asyncio.run(folder_rejected()))


# --------------------------------------------------------------------------
# end-to-end
# --------------------------------------------------------------------------
async def test_e2e(tmp_dir: Path) -> None:
    tmp_dir.mkdir(parents=True, exist_ok=True)
    rpc_port, web_port = free_port(), free_port()
    aria_httpd, fake_aria = serve_aria2(rpc_port, secret="hoster-secret", seed=False)
    host_httpd, host_state, host_port = serve_hoster(0)
    site = f"http://127.0.0.1:{host_port}"       # -> xfilesharing resolver
    mf_site = f"http://localhost:{host_port}"    # -> mediafire resolver
    state_file = tmp_dir / "hosters.json"

    config_path = tmp_dir / "config.yaml"
    config_path.write_text(yaml.safe_dump({
        "server": {"host": "127.0.0.1", "port": web_port},
        "poll_interval": 0.4,
        "aria2": {
            "managed": False,
            "rpc": {"host": "127.0.0.1", "port": rpc_port, "secret": "hoster-secret"},
        },
        "rules_enabled": False,
        "rules": [],
        "hosters": {
            "enabled": True,
            "max_active": 1,
            "poll_interval": 0.4,
            "wait_cap_seconds": 10,
            "max_attempts": 2,
            "retry_backoff_seconds": 1,
            "state_file": str(state_file),
            # Both fake sites share the loopback address, so route the two
            # hostnames of it to different resolvers: localhost exercises the
            # MediaFire code path, 127.0.0.1 the XFileSharing one.
            "resolver_domains": {"mediafire": ["localhost"], "xfilesharing": ["127.0.0.1"]},
        },
    }))

    cfg = Config(config_path)
    app = create_app(cfg)
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=web_port,
                                           log_level="error", access_log=False))
    task = asyncio.create_task(server.serve())
    base = f"http://127.0.0.1:{web_port}"

    async with aiohttp.ClientSession() as http:
        async def get(path):
            async with http.get(base + path) as res:
                return res.status, await res.json()

        async def post(path, body=None):
            async with http.post(base + path, json=body) as res:
                return res.status, await res.json()

        async def jobs() -> list[dict]:
            _, data = await get("/api/hoster")
            return data["jobs"]

        async def job_state(job_id: str) -> str:
            for job in await jobs():
                if job["id"] == job_id:
                    return job["state"]
            return "gone"

        await wait_for(lambda: server.started, 15)
        print("\ne2e: hoster queue — resolvers exposed")
        status, listing = await get("/api/hoster")
        check("GET /api/hoster works", status == 200 and listing["enabled"] and listing["jobs"] == [])
        names = {r["name"] for r in listing["resolvers"]}
        check("mediafire and xfilesharing resolvers registered",
              {"mediafire", "xfilesharing", "direct"} <= names, str(names))

        # ---- direct-link host (MediaFire shape), sequential ----------------
        print("\ne2e: direct-link host, sequential processing")
        status, added = await post("/api/hoster", {"urls": [
            f"{mf_site}/direct/one.iso",
            f"{mf_site}/direct/two.iso",
            f"{mf_site}/direct/three.iso",
        ]})
        check("three page URLs queued", status == 200 and len(added["jobs"]) == 3)
        ids = [job["id"] for job in added["jobs"]]

        # Sample the queue while it drains: never more than one active download.
        max_concurrent = 0
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            current = await jobs()
            active = [j for j in current if j["state"] in ("resolving", "downloading")]
            max_concurrent = max(max_concurrent, len(active))
            if all(j["state"] == "complete" for j in current if j["id"] in ids):
                break
            await asyncio.sleep(0.25)

        final = {j["id"]: j for j in await jobs()}
        check("all three jobs completed",
              all(final[i]["state"] == "complete" for i in ids),
              str({i: final[i]["state"] for i in ids}))
        check("only one download ran at a time", max_concurrent <= 1, f"saw {max_concurrent}")
        check("jobs kept their queue order",
              [final[i]["page_url"].rsplit("/", 1)[-1] for i in ids]
              == ["one.iso", "two.iso", "three.iso"])
        check("resolver recorded per job", all(final[i]["resolver"] == "mediafire" for i in ids))
        check("filename resolved from the host",
              final[ids[0]]["filename"] == "one.iso", final[ids[0]]["filename"])
        check("direct link captured",
              "/files/one.iso" in final[ids[0]]["direct_url"], final[ids[0]]["direct_url"])
        check("aria2 received the download",
              any(d.name == "one.iso" for d in fake_aria.downloads.values()))
        first_dl = next(d for d in fake_aria.downloads.values() if d.name == "one.iso")
        check("referer passed to aria2",
              "direct/one.iso" in (first_dl.options.get("referer") or ""),
              str(first_dl.options.get("referer")))
        check("each job finished before the next started",
              final[ids[0]]["finished_at"] <= final[ids[1]]["started_at"] + 0.5
              and final[ids[1]]["finished_at"] <= final[ids[2]]["started_at"] + 0.5)

        # ---- countdown + digits challenge --------------------------------
        print("\ne2e: XFileSharing host with countdown")
        before_step2 = host_state.step2_hits
        queued_at = time.time()
        status, added = await post("/api/hoster", {
            "url": f"{site}/xfs/archive.zip?challenge=digits&wait=2"})
        job_id = added["jobs"][0]["id"]
        done = await wait_for(lambda: _is(job_state(job_id), "complete"), 40)
        check("countdown+digits job completed automatically", done,
              await job_state(job_id))
        check("the site's two-step flow was followed",
              host_state.step1_hits >= 1 and host_state.step2_hits > before_step2)
        check("the countdown was actually waited out",
              host_state.step2_times and host_state.step2_times[-1] - queued_at >= 2.0,
              f"{(host_state.step2_times[-1] - queued_at):.1f}s")
        check("no wrong-code submissions", host_state.bad_codes == 0)

        # ---- image captcha: human types the code -------------------------
        print("\ne2e: image captcha parks the job for a human")
        status, added = await post("/api/hoster", {
            "url": f"{site}/xfs/photos.rar?challenge=code&wait=1"})
        code_job = added["jobs"][0]["id"]
        parked = await wait_for(lambda: _is(job_state(code_job), "needs_input"), 30)
        check("job parks in needs_input", parked, await job_state(code_job))
        current = {j["id"]: j for j in await jobs()}[code_job]
        interaction = current["interaction"] or {}
        check("interaction asks for a captcha code", interaction.get("kind") == "captcha_code",
              str(interaction))
        check("captcha image URL provided",
              (interaction.get("image_url") or "").endswith("/captchas/abc.jpg"),
              str(interaction.get("image_url")))
        check("internal form state is not exposed to the browser",
              "state" not in interaction, str(interaction.keys()))

        status, wrong = await post(f"/api/hoster/{code_job}/answer", {"code": "0000"})
        check("a wrong code is reported and the job stays parked",
              status == 200 and wrong["job"]["state"] == "needs_input"
              and "captcha" in (wrong["job"]["error"] or "").lower(),
              f"{status} {wrong.get('job', {}).get('error')}")
        check("the host saw the bad code", host_state.bad_codes >= 1)

        status, right = await post(f"/api/hoster/{code_job}/answer", {"code": EXPECTED_CODE})
        check("the correct code resolves the job",
              status == 200 and right["job"]["state"] in ("downloading", "complete"),
              f"{status} {right.get('job', {}).get('state')}")
        check("captcha job completes",
              await wait_for(lambda: _is(job_state(code_job), "complete"), 30),
              await job_state(code_job))

        status, no_answer = await post(f"/api/hoster/{code_job}/answer", {"code": "1"})
        check("answering a finished job is a 409", no_answer and status == 409, str(status))

        # ---- browser-only challenge + userscript hand-back ---------------
        print("\ne2e: browser-only challenge, link handed back by the userscript")
        page = f"{site}/xfs/movie.mkv?challenge=browser&wait=1"
        status, added = await post("/api/hoster", {"url": page})
        browser_job = added["jobs"][0]["id"]
        parked = await wait_for(lambda: _is(job_state(browser_job), "needs_input"), 30)
        check("reCAPTCHA job parks for the browser", parked, await job_state(browser_job))
        current = {j["id"]: j for j in await jobs()}[browser_job]
        check("interaction is marked browser-only",
              (current["interaction"] or {}).get("kind") == "browser",
              str(current["interaction"]))

        # This is exactly what the userscript posts after you solve it in-page.
        status, handback = await post("/api/userscript/add", {
            "url": f"{site}/files/movie.mkv",
            "referer": page,
            "cookie": "sid=abc",
            "userAgent": "TestUA/1.0",
        })
        check("userscript link is matched to the parked job",
              status == 200 and handback.get("matchedHosterJob") == browser_job,
              json.dumps(handback))
        check("browser-solved job completes",
              await wait_for(lambda: _is(job_state(browser_job), "complete"), 30),
              await job_state(browser_job))
        check("no stray standalone download was created for the hand-back",
              sum(1 for d in fake_aria.downloads.values() if d.name == "movie.mkv") == 1)

        # ---- Cloudflare Turnstile (the checkbox kind) --------------------
        print("\ne2e: Cloudflare Turnstile parks with checkbox-specific wording")
        status, added = await post("/api/hoster", {
            "url": f"{site}/xfs/turnstiled.zip?challenge=turnstile&wait=1"})
        ts_job = added["jobs"][0]["id"]
        parked = await wait_for(lambda: _is(job_state(ts_job), "needs_input"), 30)
        check("turnstile job parks for the browser", parked, await job_state(ts_job))
        current = {j["id"]: j for j in await jobs()}[ts_job]
        message = (current["interaction"] or {}).get("message", "")
        check("interaction is browser-kind", (current["interaction"] or {}).get("kind") == "browser")
        check("wording says it is just a checkbox",
              "checkbox" in message.lower() and "turnstile" in message.lower(), message[:120])
        await post(f"/api/hoster/{ts_job}/cancel")

        # ---- a host behind a Cloudflare wall ----------------------------
        print("\ne2e: host behind Cloudflare, unblocked by shared cookies")
        blocked_before = host_state.cf_blocks
        status, added = await post("/api/hoster", {
            "url": f"{site}/xfs/gated.zip?cf=1&challenge=none&wait=1"})
        cf_job = added["jobs"][0]["id"]
        parked = await wait_for(lambda: _is(job_state(cf_job), "needs_input"), 30)
        check("a Cloudflare interstitial parks the job rather than failing it", parked,
              await job_state(cf_job))
        check("the fake host did serve the interstitial", host_state.cf_blocks > blocked_before)
        current = {j["id"]: j for j in await jobs()}[cf_job]
        message = (current["interaction"] or {}).get("message", "")
        check("message names Cloudflare and explains the way through",
              "cloudflare" in message.lower()
              and ("cookie" in message.lower() or "clearance" in message.lower()),
              message[:140])

        status, empty_creds = await get("/api/hoster/cookies")
        check("no cookies stored yet", status == 200 and empty_creds["credentials"] == [],
              str(empty_creds))

        # This is what the userscript posts after the browser clears the wall.
        status, shared = await post("/api/hoster/cookies", {
            "domain": "127.0.0.1",
            "cookies": {"cf_clearance": CF_CLEARANCE, "sid": "abc"},
            "user_agent": "TestUA/1.0",
        })
        check("cookies accepted", status == 200 and shared["cookies"] == 2, json.dumps(shared))
        check("sharing cookies re-queues the blocked job", shared["requeued"] >= 1,
              str(shared.get("requeued")))
        check("the job resolves once the clearance cookie is available",
              await wait_for(lambda: _is(job_state(cf_job), "complete"), 40),
              await job_state(cf_job))

        status, creds = await get("/api/hoster/cookies")
        entry = creds["credentials"][0]
        check("stored credentials are summarised", entry["domain"] == "127.0.0.1"
              and entry["cookies"] == 2, json.dumps(entry))
        check("clearance cookie is flagged", entry["has_cloudflare_clearance"] is True)
        check("cookie names are listed but VALUES are never returned",
              "cf_clearance" in entry["names"] and CF_CLEARANCE not in json.dumps(creds),
              json.dumps(entry))
        check("the matching user agent is kept alongside",
              entry["user_agent"] == "TestUA/1.0", entry["user_agent"])

        _, snap = await get("/api/hoster")
        check("cookie values never appear in the queue payload",
              CF_CLEARANCE not in json.dumps(snap))
        creds_file = state_file.with_name("hoster-cookies.json")
        check("cookies persist to their own file", creds_file.is_file())
        check("cookie file is not world-readable",
              (creds_file.stat().st_mode & 0o077) == 0,
              oct(creds_file.stat().st_mode))

        status, bad = await post("/api/hoster/cookies", {"domain": "x.example", "cookies": {}})
        check("empty cookie payload is a 400", status == 400)

        # ---- queue controls ----------------------------------------------
        print("\ne2e: queue controls")
        status, _ = await post("/api/hoster/pause", {"paused": True})
        status, added = await post("/api/hoster", {"urls": [
            f"{mf_site}/direct/paused-a.bin", f"{mf_site}/direct/paused-b.bin"]})
        pa, pb = [j["id"] for j in added["jobs"]]
        await asyncio.sleep(2)
        check("a paused queue starts nothing",
              await job_state(pa) == "queued" and await job_state(pb) == "queued",
              f"{await job_state(pa)}, {await job_state(pb)}")

        status, _ = await post("/api/hoster/reorder", {"ids": [pb, pa]})
        order = [j["id"] for j in await jobs() if j["id"] in (pa, pb)]
        check("reorder moves a job up the queue", order == [pb, pa], str(order))

        status, _ = await post(f"/api/hoster/{pa}/cancel")
        check("cancel marks the job cancelled", await job_state(pa) == "cancelled")
        async with http.delete(base + f"/api/hoster/{pb}") as res:
            check("delete removes the job", res.status == 200)
        check("deleted job is gone", await job_state(pb) == "gone")
        async with http.delete(base + "/api/hoster/nope") as res:
            check("deleting an unknown job is a 404", res.status == 404)

        status, _ = await post("/api/hoster/pause", {"paused": False})
        status, cleared = await post("/api/hoster/clear-finished")
        check("clear-finished drops completed jobs", status == 200 and cleared["removed"] >= 4,
              str(cleared))

        # ---- failure paths ------------------------------------------------
        print("\ne2e: failure handling")
        status, added = await post("/api/hoster", {"url": f"{site}/dead"})
        dead_job = added["jobs"][0]["id"]
        failed = await wait_for(lambda: _is(job_state(dead_job), "failed"), 30)
        check("a dead link fails permanently", failed, await job_state(dead_job))
        current = {j["id"]: j for j in await jobs()}[dead_job]
        check("failure reason is recorded", bool(current["error"]), str(current["error"]))
        check("a permanent failure is not retried", current["attempts"] == 1,
              f"attempts={current['attempts']}")

        status, _ = await post(f"/api/hoster/{dead_job}/retry")
        check("retry re-queues a failed job",
              await job_state(dead_job) in ("queued", "resolving", "failed"))

        status, added = await post("/api/hoster", {
            "url": f"{site}/xfs/slow.zip?challenge=none&wait=30"})
        cap_job = added["jobs"][0]["id"]
        capped = await wait_for(
            lambda: _has_error(jobs(), cap_job, "cap"), 30)
        check("a countdown over wait_cap_seconds is refused", capped,
              str({j["id"]: j["error"] for j in await jobs() if j["id"] == cap_job}))

        status, empty = await post("/api/hoster", {"urls": []})
        check("adding nothing is a 400", status == 400)

        # ---- persistence + live state ------------------------------------
        print("\ne2e: persistence and live state")
        check("queue state file written", state_file.is_file())
        saved = json.loads(state_file.read_text())
        check("saved file holds the jobs", isinstance(saved.get("jobs"), list) and saved["jobs"])
        check("saved jobs keep their state",
              all("state" in job and "page_url" in job for job in saved["jobs"]))

        status, snapshot = await get("/api/state")
        check("hoster queue rides along in the state snapshot",
              "hosters" in snapshot and "jobs" in snapshot["hosters"],
              str(list(snapshot.keys())))

        status, ping = await get("/api/userscript/ping")
        check("ping advertises the hoster domains",
              any("mediafire.com" == d for d in ping.get("hosterDomains", [])),
              str(ping.get("hosterDomains")))

    server.should_exit = True
    try:
        await asyncio.wait_for(task, timeout=15)
    except asyncio.TimeoutError:
        pass
    aria_httpd.shutdown()
    fake_aria.stop()
    host_httpd.shutdown()


async def _is(coro, expected: str) -> bool:
    return (await coro) == expected


async def _has_error(coro, job_id: str, needle: str) -> bool:
    for job in await coro:
        if job["id"] == job_id and needle in (job["error"] or "").lower():
            return True
    return False


# create_app is imported late so tests/test_manager.py can import this module.
from aria2c_manager.api import create_app  # noqa: E402


def main() -> int:
    import tempfile

    from tests.harness import summary

    with tempfile.TemporaryDirectory(prefix="aria2c-hoster-test-") as tmp:
        test_units()
        asyncio.run(test_e2e(Path(tmp) / "h1"))
    return summary()


if __name__ == "__main__":
    raise SystemExit(main())
