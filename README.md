# aria2c manager

A background download server built on aria2c, with a web UI to manage the queue
and an HTTP endpoint that a Tampermonkey userscript posts to. Every aria2
capability that matters for downloading — queueing, splitting a file into parts,
parallel downloads, parallel connections per server, speed limits, BitTorrent —
is exposed in the UI, and a small rules engine can take automatic action on a
download when it misbehaves (for example: *speed under 50 KiB/s for 3 seconds →
pause and resume*).

It also queues **file-hosting-site pages** — MediaFire, kenfiles and XFileSharing
clones — resolving each to a fresh direct link when its turn comes and running
them one at a time.

```
Tampermonkey ──POST /api/userscript/add──┐
                                         ├─→ manager (FastAPI) ──JSON-RPC──→ aria2c
Browser UI ──REST + SSE─────────────────┘        │
                                                  ├── rules engine (1 Hz tick)
                                                  └── hoster queue (page URL → direct link)
```

The manager owns the aria2c process: it spawns it, waits for its RPC to answer,
restarts it if it dies, and shuts it down cleanly on exit — including on SIGHUP,
so closing the terminal does not leave an orphan behind. If it ever does find a
leftover aria2c on its RPC port (after a `kill -9`, say), it adopts that process
instead of failing to start.

---

## 1. Install

aria2c itself is the only external requirement:

```bash
sudo pacman -S aria2        # Arch
sudo apt install aria2      # Debian/Ubuntu
sudo dnf install aria2      # Fedora
```

The Python side needs `fastapi`, `uvicorn`, `aiohttp` and `PyYAML`, which are
already present on this machine's system Python. On another machine:

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
```

Live updates use Server-Sent Events, so no `websockets` package is needed, and
`.torrent` uploads travel as base64 JSON, so no `python-multipart` either.

## 2. Run

```bash
cp config.example.yaml config.yaml     # optional; defaults work as-is
./run.sh                               # or: python3 -m aria2c_manager
```

```
aria2c-manager 1.0.0
  web UI     http://127.0.0.1:6810/
  userscript POST http://127.0.0.1:6810/api/userscript/add
  config     /home/you/GitHub/Aria2C/config.yaml
```

Useful flags:

| Flag | Purpose |
| --- | --- |
| `--port 6810` / `--host` | override the listen address |
| `--open` | open the web UI in a browser |
| `--no-aria2` | attach to an aria2c you already run instead of spawning one |
| `--print-argv` | show the exact aria2c command line that would be used |
| `--print-config` | show the effective config after merging defaults |
| `-c FILE` | use a different config file |

### Run it in the background at login

```bash
mkdir -p ~/.config/systemd/user
cp systemd/aria2c-manager.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now aria2c-manager
systemctl --user status aria2c-manager
```

`KillMode=control-group` in the unit means stopping the service also stops the
aria2c child, leaving no orphaned downloader behind. Adjust `WorkingDirectory`
if the checkout lives somewhere other than `~/GitHub/Aria2C`.

### Closing the terminal, and leftover aria2c processes

`aria2c` runs in its own session so that a stray Ctrl-C cannot interrupt a
download mid-write. The flip side is that it can outlive its manager, and it holds
the RPC port while it does. That is handled:

| What happened | What the manager does |
| --- | --- |
| Terminal closed (**SIGHUP**), Ctrl-C (SIGINT), `systemctl stop` (SIGTERM) | shuts down gracefully: saves the session, stops aria2c, leaves nothing behind |
| Manager `kill -9`'d, or the machine lost power | next run finds the leftover aria2c and **adopts** it — downloads keep going, and the UI shows it as adopted with its real pid |
| A leftover aria2c that no longer accepts our secret | reclaimed: SIGTERM (which makes it save its session), then replaced |
| Something *else* is on the RPC port | refuses to touch it and says so plainly — change `aria2.rpc.port` or stop that process |

If you would rather downloads *continue* after you close the terminal, set
`aria2.stop_on_exit: false`. The manager then leaves aria2c running on exit and
adopts it again next time.

## 3. Tampermonkey

Open `userscript/aria2c-catcher.user.js` in Tampermonkey (drag the file into the
browser, or Dashboard → Utilities → Import) and install it. Then use the
Tampermonkey tray menu on any page:

| Menu entry | What it does |
| --- | --- |
| Send this page URL to aria2c | queues the current URL |
| Send selected links to aria2c | queues every link inside your text selection |
| Send ALL downloadable links | queues every matching link on the page (asks first) |
| Send a URL by hand… | prompts for a URL or magnet |
| Auto-capture download links | intercept left-clicks on links that look like downloads |
| Alt+click sends any link | send any link with Alt held, even with capture off |
| Add downloads paused | queue new downloads in a paused state |
| Server URL / directory / extensions / minimum size | per-browser settings |
| Skip this site | exclude the current hostname from auto-capture |
| Test connection | verifies the manager and aria2c are up |
| **Queue THIS PAGE in the hoster queue** | send the current hoster page to the queue (§5) |
| **Queue hoster links on this page…** | queue every link to a supported host |
| **Send this page's generated link to the queue** | after solving a captcha, hand the link back to its job |
| **Auto-run this hoster page** | drive the wait/submit/hand-back flow now (also armed by the UI's *Open page ▸*) |
| **Share this site's cookies with the manager** | pass this host's cookies + UA so the manager can reuse a Cloudflare clearance |
| Auto-run hoster pages when opened from the UI | toggle the auto-flow (on by default; never runs during ordinary browsing) |

Each request carries `document.cookie`, the page URL as `Referer`, and the
browser's `User-Agent`, so downloads behind a login keep working. Magnet links
are captured by default. `blob:` and `data:` URLs are ignored — the server
cannot fetch those.

Anything else can post to the same endpoint:

```bash
curl -X POST http://127.0.0.1:6810/api/userscript/add \
  -H 'Content-Type: application/json' \
  -d '{"url": "https://example.com/big.iso", "filename": "big.iso"}'
```

## 4. Custom download actions (the rules engine)

Rules live in `config.yaml` and are editable from the **Rules** tab. Each rule is
evaluated for every download once per poll tick (1 s by default). When all of its
conditions hold **continuously** for `for_seconds`, the action fires once and
that download enters `cooldown_seconds` for that rule.

The default rule is the requested behaviour:

```yaml
rules:
  - name: stall-recovery
    enabled: true
    when:
      statuses: [active]
      speed_below: 51200      # bytes/s — 50 KiB/s
      for_seconds: 3
      min_age_seconds: 8      # ignore the ramp-up right after a start
      max_progress: 99.0      # leave a nearly-finished download alone
    action: pause_resume
    resume_after_seconds: 1.5
    cooldown_seconds: 25      # don't re-fire immediately
    max_triggers: 20          # give up after this many attempts
```

**Conditions** (all optional; all listed ones must match)

| Key | Meaning |
| --- | --- |
| `statuses` | which aria2 statuses the rule applies to (default `[active]`) |
| `speed_below` / `speed_above` | download speed in bytes/s |
| `speed_source` | `hybrid` (default), `measured` or `aria2` — see the note below |
| `connections_below` | fewer than N live connections |
| `min_age_seconds` | ignore downloads younger than this |
| `min_progress` / `max_progress` | percentage window |
| `min_size` | total size at least N bytes |
| `torrent_only` / `http_only` | restrict by download kind |
| `name_matches` | regex against the download name |

**Actions**

| Action | Effect |
| --- | --- |
| `pause_resume` | pause, wait `resume_after_seconds`, unpause — the classic stall fix. Also takes back the concurrency slot (see below); `preserve_slot: false` opts out |
| `force_pause_resume` | same, but drops connections immediately |
| `restart` | remove and re-add with the same URLs and options (HTTP/FTP only) |
| `set_option` | apply an `options:` mapping to that download (e.g. fewer connections) |
| `stop` | pause and leave it paused |
| `log_only` | record it in the log and do nothing |

### Why the speed you see lags the bytes

aria2's `downloadSpeed` is a **moving average**, so it keeps reporting a healthy
figure for several seconds after the transfer has actually stopped — the size
freezes while the speed is still showing 5 MB/s, then it decays. That is aria2's
own smoothing, not a reporting delay in this manager.

Because a stall rule that trusts that number reacts seconds late, the manager also
computes `measuredSpeed`: bytes actually added to the file over the last ~3
seconds. The window spans a few samples rather than one tick, because aria2
completes data in piece-sized chunks and a merely-slow download can add nothing
for a single second without being stalled.

Which figure rules use is your choice — **Rules tab → "Judge speed by"**, or
`rules_speed_source` in the config, or `when.speed_source` on one rule:

| Value | Behaviour |
| --- | --- |
| `hybrid` *(default)* | the measured figure when available, else aria2's |
| `measured` | measured only. Reacts immediately; while no measurement exists yet a rule will not fire at all, so it never acts on a guess |
| `aria2` | aria2's own number, lag included |

The download row shows aria2's number normally, and both when they disagree
materially — that gap is exactly what makes a stalled download look alive.

### Pausing hands the slot to the next download

This one is aria2's design, not a setting: pausing an active download **frees a
concurrency slot**, and aria2 immediately starts the next queued item. Unpausing
puts your download back in the *queue*, not back to running — so with
`max-concurrent-downloads: 1` a stall fix would silently swap the stalled download
with the next one, every time it fired.

`pause_resume` therefore takes the slot back: it moves the download to the head of
the queue and, if something grabbed the slot meanwhile, bounces that one so aria2
promotes yours again (the bounced download goes back to waiting, next in line).
The log says which happened — *"kept its slot"*, *"slot reclaimed"*, or *"could not
get its slot back — it is queued next"*. Set `preserve_slot: false` on the rule for
aria2's untouched behaviour.

`min_age_seconds` is counted from the moment a download **starts transferring**,
not from when it was queued. A download can sit in the queue for minutes; it still
gets its full grace period once it actually starts, and a pause/resume restarts
that period too.

`cooldown_seconds` and `max_triggers` are the safety valves that stop a rule from
thrashing a download. The **Rules engine** switch in the header disables all
rules at once, and each download's row shows a live countdown badge
(`stall-recovery 2.1/3s`) plus a trigger count, so you can see a rule building up
before it fires. Every trigger is written to the **Log** tab.

## 5. Hoster queue (MediaFire, kenfiles, …)

The **Hosters** tab takes *file page* links instead of direct links. Each one is
resolved to a direct link only when its turn comes — these links expire fast and
are often session-bound — handed to aria2, and the next job starts once the
current download finishes.

```
paste page URLs ─→ queued ─→ resolving ─→ downloading ─→ complete ─→ next job
                                 │
                                 └─ needs you (captcha) ─answer─→ downloading
```

Two site shapes are covered, which between them account for most hosts:

| Shape | Example | How it goes |
| --- | --- | --- |
| **Direct** — the page holds the link | mediafire.com | Fully automatic. The link is read out of the download button, verified with a HEAD (filename + size), and downloaded. |
| **Wait + challenge** — XFileSharing script | kenfiles.com | The two-step `op=download1` → `op=download2` flow is followed and the countdown waited out. Challenges: none → automatic; the classic ordered-digits kind (plain text in the HTML) → read off the page; an **image code** → shown to you in the UI, you type it; **Turnstile / reCAPTCHA / hCaptcha** → handed to the browser, see below. |

### Cloudflare Turnstile is one click (often zero)

Turnstile is only a checkbox for a human, but the token it mints
(`cf-turnstile-response`) is issued by Cloudflare's own JavaScript running in a
real browser — a server-side scraper cannot produce it however easy the click is.
So the browser does that one step, and the userscript does everything around it.

Click **Open page ▸** on the job. That opens the page with `#a2m-auto`, which arms
the userscript to:

1. submit the first form (`op=download1`),
2. wait out the countdown itself,
3. wait for the verification box to clear — **you tick it**, or Turnstile's
   invisible/managed mode clears with no click at all,
4. submit `op=download2` the moment the token appears,
5. find the generated link and hand it back to the waiting job.

So the whole job is: click *Open page*, tick a box, done. No captcha is ever
solved programmatically and no solving service is involved. If you would rather
not use the auto-flow, turn it off in the userscript menu and either paste the
link into the job's box or use *“Send this page's generated link to the queue”*.

### When Cloudflare guards the page itself

If a host puts Cloudflare in front of the *page* (a "Just a moment…"
interstitial), the manager's own request never sees HTML. It detects this, parks
the job with a clear reason instead of failing it, and there are two ways
forward:

* **Share the clearance** — the userscript's *“Share this site's cookies with the
  manager”* (also done automatically during the auto-flow) posts that host's
  cookies plus the matching user agent. Any job parked on a Cloudflare wall for
  that host is then re-queued automatically and usually resolves server-side from
  then on. `cf_clearance` is HttpOnly, so this needs Tampermonkey's `GM_cookie`
  grant — the script requests it; without it the cookie cannot be read and the
  hand-back route below is the one that works.
* **Hand back the finished link** — as with any browser challenge.

Shared cookies live in `hoster-cookies.json` next to the queue state, written
`0600`. The API reports which hosts have cookies and their *names* only; values
are never returned in any response.

Adding links: paste into the Hosters tab, or from the browser use the userscript's
*“Queue THIS PAGE in the hoster queue”* / *“Queue hoster links on this page…”*, or
POST them:

```bash
curl -X POST http://127.0.0.1:6810/api/hoster \
  -H 'Content-Type: application/json' \
  -d '{"urls": ["https://www.mediafire.com/file/KEY/name.bin/file"]}'
```

Per-job controls are retry, cancel and remove; the queue itself can be paused,
reordered and cleared of finished jobs, and it survives a restart via
`hosters.state_file`. An **XFileSharing clone needs no new code** — add its domain
to `hosters.xfilesharing_domains`. Anything on an unrecognised host is treated as
a direct link.

Verified against the live sites: a real MediaFire page resolved and downloaded a
10 MiB file end to end (`complete`, 10,485,760 bytes on disk). kenfiles.com was
confirmed to be XFileSharing-based from its markup, but the full flow was
exercised against `tests/fake_hoster.py`, not a live kenfiles file — see the note
at the end of §9.

## 6. Web UI

**Downloads** — one row per download with progress, speed, ETA, live connection
count and seeders. Filter chips by status, plus a name filter. Row actions:
pause, resume, move to top / up / down the queue, retry, remove. Expanding a row
shows a piece map of the downloaded parts, the file list (with per-file selection
for torrents), the live per-connection speeds, the URLs, peers, and editable
per-download options (split, connections per server, speed limits).

**Add download** — URLs (one per line, or as mirrors of one file), or a
`.torrent`/`.metalink` file; destination directory, output filename, connections
per server, split, minimum part size, speed limit, referer, user-agent, cookie,
extra headers, proxy, checksum, queue position, and add-paused.

**Settings** — every global aria2 option, grouped (queue & parallelism, speed
limits, retries, disk, HTTP, BitTorrent) with an "all options" section for the
rest. Edits apply to the running aria2c immediately *and* are written to
`config.yaml`, so they survive a restart. Also shows the aria2c process state
(pid, version, uptime, restarts, log path) with a restart button.

**Hosters** — the queue described in §5.

**History** — the last filter chip on the Downloads tab. aria2's session file only
keeps *unfinished* downloads, so completed ones would vanish on the next restart.
The manager records every download it sees finish in `history.json`, which
survives restarts and aria2's own purge; each row can be queued again from its
recorded URL or forgotten. Files on disk are never touched by clearing history.

> **In-progress downloads are not at risk.** They live in aria2's session file
> plus the `.aria2` control file beside the partial file, and resume on restart.
> Verified: a download interrupted at 13% came back at 31% after a restart and
> finished to 100% as one clean file.

**Header** — global download/upload speed, counts, global speed limits and max
concurrent downloads, pause all / resume all / purge finished.

Press `n` anywhere to open the add dialog.

## 7. HTTP API

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/state` | latest snapshot |
| `GET` | `/api/events` | SSE stream of `state`, `event`, `backlog` frames |
| `GET` | `/api/log` | recent events and rule triggers |
| `POST` | `/api/downloads` | add URIs (`{uris, options, position, paused, mirrors}`) |
| `POST` | `/api/downloads/file` | add a base64 `.torrent`/`.metalink` |
| `GET` | `/api/download/{gid}` | detail: status, files, uris, options, servers, peers, piece map |
| `POST` | `/api/download/{gid}/pause\|resume\|retry` | per-download commands |
| `POST` | `/api/download/{gid}/options\|position\|select` | change options, queue position, selected files |
| `DELETE` | `/api/download/{gid}` | remove (`?force=&purge=`) |
| `POST` | `/api/global/pause-all\|resume-all\|purge\|save-session` | queue-wide commands |
| `GET`/`POST` | `/api/global/options` | read/write global aria2 options |
| `GET`/`POST` | `/api/rules` | read/replace rules; `POST /api/rules/{name}/toggle` |
| `GET` | `/api/aria2/status`, `POST /api/aria2/restart` | process supervision |
| `GET` | `/api/hoster` | queue state: jobs, counts, registered resolvers |
| `POST` | `/api/hoster` | queue page URLs (`{urls, options, position}`) |
| `POST` | `/api/hoster/{id}/answer` | supply a captcha `code` or a `direct_url` |
| `POST` | `/api/hoster/{id}/retry\|cancel`, `DELETE /api/hoster/{id}` | per-job control |
| `POST` | `/api/hoster/pause\|reorder\|clear-finished` | queue-wide control |
| `GET`/`POST` | `/api/hoster/cookies` | list hosts with shared cookies (names only) / store cookies + UA for a host |
| `GET` | `/api/history` | finished downloads recorded across restarts (`?limit=&status=`) |
| `POST` | `/api/history/readd` | queue a past download again (`{key}`) |
| `POST` | `/api/history/remove`, `/api/history-clear` | forget one entry / all of them |
| `POST` | `/api/userscript/add` | lenient intake used by the userscript (auto-matches a parked hoster job when the referer is its page) |
| `POST` | `/api/userscript/hoster` | queue a hoster page URL from the browser |
| `GET` | `/api/userscript/ping` | readiness probe for the userscript |

aria2 errors come back as HTTP 502 with the aria2 message; if aria2c is not
running at all, commands return 503 explaining why rather than a bare 500.

## 8. Security

There is **no authentication**, by design — the server binds `127.0.0.1` only,
and CORS is open because the userscript posts from arbitrary page origins. Do not
bind it to `0.0.0.0`: anything that can reach the port can queue downloads and
read your download list. The manager warns on startup if you do.

The aria2 RPC secret is generated randomly on first run and stored at
`~/.local/share/aria2c-manager/rpc-secret` with `0600` permissions (a secret you
set explicitly in `config.yaml` is used as-is instead). It is kept on disk rather
than regenerated per run for a functional reason: without it, a new manager cannot
authenticate to an aria2c left over from a previous run, so that process could
neither be adopted nor asked to stop. `/api/config` redacts it.

Cookies shared from the browser for a hoster (§5) are session credentials for
those sites. They are stored in `hoster-cookies.json` with `0600` permissions,
kept out of the queue's own state file, and never included in an API response —
`/api/hoster/cookies` returns cookie *names* and counts only. Delete that file to
revoke them.

## 9. Tests

The suite runs the whole stack against a fake aria2 RPC server, so **no aria2c
installation is required** to run it:

```bash
python3 tests/test_manager.py     # 282 checks (manager + hoster queue)
python3 tests/test_hosters.py     # just the hoster queue (119)
```

It covers config merging and persistence, the aria2c command line, the REST and
SSE surface, adding/pausing/removing/repositioning, global options, the
userscript intake (including that a `../../escape.iso` filename is reduced to a
basename), managed-mode process supervision (spawn → SIGKILL → automatic
restart → clean shutdown), the orphan cases above (SIGHUP exits with code 0 and
leaves no aria2c; a SIGKILL'd manager's orphan is adopted by the next run and
stopped cleanly; a foreign listener is reported and never killed), and — the
interesting one — that the stall-recovery
rule really does pause and resume a download whose speed drops, while leaving a
healthy download untouched.

The hoster suite runs both site shapes against `tests/fake_hoster.py`, whose
MediaFire page markup is copied from a live page: three page URLs draining
strictly one at a time and in order, each finishing before the next starts; the
two-step wait flow with the countdown genuinely waited out; an image captcha
parking the job, rejecting a wrong code and accepting the right one; a
reCAPTCHA job parking for the browser and then being completed by a simulated
userscript hand-back (with no stray duplicate download); a Turnstile job parking
with checkbox-specific wording; a host behind a Cloudflare wall parking and then
resolving once the browser shares its `cf_clearance` cookie — including that the
cookie values never appear in any response and the file is not world-readable;
dead links, countdowns over the cap, cancel/reorder/delete, and queue
persistence.

Both hosts are now verified against the **live** sites. MediaFire resolves and
downloads end to end; kenfiles' two-step flow is followed and parks on its
Cloudflare Turnstile checkbox, with the real countdown (30 s) and filename read
off the page. Three live-only bugs that the fake site could not have caught are
pinned as regression tests from the real markup:

* the literal text `"file not found"` sits in a JavaScript template on a healthy
  kenfiles page, and whole-page substring matching aborted every job;
* every Cloudflare-fronted site loads a `challenge-platform` beacon script, which
  was being read as a challenge interstitial;
* the page's own canonical URL matched the generic link sweep, so a job "resolved"
  to the HTML page and would have downloaded that instead of the file.

The rule now is that **real content wins**: if a page yields a form or a plausible
link, no string heuristic may override it, and a `.html` URL is never accepted as
a file. To inspect any host yourself:

```bash
# what the resolver sees, without touching the queue
python3 -c "
import asyncio, aiohttp, sys
sys.path.insert(0, '.')
from aria2c_manager.hosters import build_registry, pick_resolver
async def main(url):
    r = pick_resolver(url, build_registry(None))
    async with aiohttp.ClientSession() as s:
        print(r.name, '->', await r.resolve(s, url))
asyncio.run(main('PASTE_A_KENFILES_URL'))
"
```

Other tools:

```bash
python3 tests/fake_aria2.py --port 6800     # fake aria2 you can point the manager at
python3 -m aria2c_manager --no-aria2        # ...then attach to it

python3 tests/fake_hoster.py --port 8770    # fake MediaFire + XFileSharing sites

# Render the UI to a self-contained HTML file (screenshot-able offline)
python3 tests/render_ui.py --base http://127.0.0.1:6810 --tab downloads --expand \
    --out /tmp/ui.html
```

`tests/fake_aria2.py` seeds a download that deliberately stalls after 4 seconds,
which is the quickest way to watch a rule fire without waiting for a real server
to misbehave.

## 10. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `aria2c binary 'aria2c' not found in PATH` | install aria2, or set `aria2.binary` to a full path |
| `aria2c exited during startup` | usually an invalid option in `aria2.options`; check `~/.local/share/aria2c-manager/aria2.log`, or run `--print-argv` |
| Userscript says "cannot reach the manager" | manager not running, or the `@connect`/server URL does not match your port |
| Unfinished downloads did not come back after a restart | they resume from `aria2.session_file` (written every 30 s and on clean shutdown) plus the `.aria2` file beside the partial download — check both still exist |
| Completed downloads vanished from the list | aria2 never persists finished downloads; the manager's own History filter keeps them (`history.file`) |
| An action reports "aria2c is not running" while it clearly is | fixed in this build: aria2 answers ordinary errors with HTTP 400 and a JSON body, which was being read as a dead daemon. Errors now show aria2's real message |
| After closing the terminal, a rerun says "aria2c exited during startup" | fixed in this build: SIGHUP now shuts down cleanly, and any leftover aria2c is adopted or reclaimed. If you still see it, something unrelated holds the port — check with `ss -lptn "sport = :6800"` |
| A rule fires over and over | raise `cooldown_seconds` / `min_age_seconds`, or lower `max_triggers` |
| A rule fires on a download that just started | fixed in this build: `min_age_seconds` now counts from when it started transferring, not from when it was queued |
| Speed shown does not match the bytes arriving | aria2's figure is a moving average — see §4. The row shows the measured figure alongside it when they diverge |
| "Clear history" appears to do nothing | fixed in this build: dismissals are remembered, *and* aria2's own finished results are purged so the rows also leave the Downloads list |
| A stall fix makes the download swap places with the next one | fixed in this build: the action reclaims its concurrency slot. See §4 |
| A hoster job says "no download link in the final response" | the site's HTML changed, or the challenge answer was wrong — retry the job; if it persists the resolver's selectors need updating |
| A hoster job is stuck in "needs you" | it needs a captcha: type the code, or click *Open page ▸* and let the userscript drive it |
| Hoster job says "Cloudflare challenge page" | open the page once and use *Share this site's cookies*; grant `GM_cookie` in Tampermonkey so the HttpOnly `cf_clearance` can be read |
| Shared cookies stopped working | `cf_clearance` expires and is tied to the UA that earned it — share again from the same browser |
| Hoster job fails with "Host wants a 300s wait" | raise `hosters.wait_cap_seconds` |

## Layout

```
aria2c_manager/
  __main__.py     CLI entrypoint
  config.py       YAML config: defaults, merge, persistence
  rpc.py          async aria2 JSON-RPC client (HTTP transport)
  supervisor.py   spawn / health-check / restart / shut down aria2c
  state.py        1 Hz poller, snapshot normalisation, SSE fan-out
  rules.py        custom download actions
  hostqueue.py    sequential hoster queue (page URL -> aria2)
  hosters/        one module per site shape
    base.py         resolver contract + HTML helpers
    mediafire.py    direct-link host
    xfilesharing.py wait + challenge hosts (kenfiles and clones)
  api.py          FastAPI routes
  static/         web UI (no build step, no dependencies)
userscript/       Tampermonkey catcher
tests/            fake aria2, fake hoster sites, suites, UI render harness
systemd/          user service unit
```
