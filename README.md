# aria2c manager

A background download server built on aria2c, with a web UI to manage the queue
and a browser extension that hands the browser's own downloads to it. Every aria2
capability that matters for downloading — queueing, splitting a file into parts,
parallel downloads, parallel connections per server, speed limits, BitTorrent —
is exposed in the UI, and a small rules engine can take automatic action on a
download when it misbehaves (for example: *speed under 50 KiB/s for 3 seconds →
pause and resume*).

```
Extension ─────POST /api/intake/add─────┐
                                         ├─→ manager (FastAPI) ──JSON-RPC──→ aria2c
Browser UI ──REST + SSE─────────────────┘        │
                                                  └── rules engine (1 Hz tick)
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
  intake     POST http://127.0.0.1:6810/api/intake/add
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

## 3. Browser extension

`extension/` is the browser half: it takes over the browser's own downloads and
hands them here. Firefox is the supported target; the same directory also loads
in Chromium.

**Install it** — pick one:

| | How | Survives a browser restart |
| --- | --- | --- |
| From AMO | Once published, one click from the add-on's page | yes, and auto-updates |
| Signed file | `./extension/build.sh sign unlisted` → open the `.xpi` in Firefox (`about:addons` → gear → *Install Add-on From File*) | yes |
| Unpacked, Firefox | `about:debugging#/runtime/this-firefox` → *Load Temporary Add-on* → `extension/manifest.json` | no — gone on restart |
| Unpacked, Chromium | `chrome://extensions` → *Developer mode* → *Load unpacked* → `extension/` | yes |

Signing needs a free AMO API key; `extension/store/listing.md` has the
submission material, and `extension/build.sh` wraps the packaging. Then open the
extension's Settings and check the server URL matches `server.port` in
`config.yaml`.

**It takes over the browser's own downloads.** Anything the browser starts to
download is cancelled, wiped from the download list, and queued in aria2c
instead, with the page's cookies, referer and user-agent attached — so a
login-protected file, a `Content-Disposition` attachment or a JavaScript-triggered
download all end up in the queue with no clicking. Cookies come from the
browser's cookie store rather than `document.cookie`, so `HttpOnly` session
cookies travel with the request too. `blob:` and `data:` downloads are left
alone: aria2 cannot fetch those.

On top of that:

| Surface | What it does |
| --- | --- |
| Toolbar popup | live speed, active/queued counts, progress of what is running, a box to paste a URL or magnet, and a per-site *skip auto-capture* switch |
| Badge | number of active downloads, `!` when the manager is unreachable |
| Right-click a link / image / video / audio | send just that one |
| Right-click a page | send the page URL, or every downloadable link on it |
| Right-click a selection | send every link inside it |
| Click capture | left-click on a magnet, or on a link the browser would *render* rather than download, sends it here instead |
| Alt+click | sends any link, even with capture off |
| Settings page | server URL, save directory, add-paused, minimum size, which extensions count, per-host blocklist, notification style |

Anything else can post to the same endpoint:

```bash
curl -X POST http://127.0.0.1:6810/api/intake/add \
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

## 5. Web UI

The browser UI is **opt-in**: `server.web_ui` defaults to `false`, because the
DankMaterialShell widget and the browser extension both drive the API directly
and most sessions never open a browser tab for it. Three ways to turn it on:

* the **Web UI** switch in the widget's Settings tab, then *Restart manager*;
* `server.web_ui: true` in `config.yaml`;
* `python3 -m aria2c_manager --web-ui` for one run (`--open` implies it).

Mounting the UI can only happen at startup, so the switch writes the config and
asks for a restart — `POST /api/restart` exits cleanly and the service unit
(`Restart=always`) brings the manager straight back.

With it off, `/` returns a short JSON note saying so and everything under `/api`
is unchanged. What the UI actually costs while idle is one 1 Hz poll of aria2 —
and that now backs off to `poll_interval_idle` (5 s) whenever nothing is
downloading *and* no UI is connected to the event stream, so an idle manager
with no windows open barely ticks. Any command wakes it immediately.

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

**History** — the last filter chip on the Downloads tab. aria2's session file only
keeps *unfinished* downloads, so completed ones would vanish on the next restart.
The manager records every download it sees finish in `history.json`, which
survives restarts and aria2's own purge; each row can be queued again from its
recorded URL or forgotten. Files on disk are never touched by clearing history.

> **In-progress downloads are not at risk.** They live in aria2's session file
> plus the `.aria2` control file beside the partial file, and resume on restart.
> Verified: a download interrupted at 13% came back at 31% after a restart and
> finished to 100% as one clean file.

**Header** — the live throughput as the headline figure, then active/queued/done/
failed counts, and pause all / resume all / purge finished. Global speed limits
live under *Settings* with the rest of the aria2 options, where they belong.

**Downloads** — filter chips carry their own counts (*All* and *Complete*
included), each row shows its progress as both a wash across the card and a rail
along its bottom edge, and a finished download whose file has since been moved or
deleted is marked **file missing**. *Select* turns on bulk mode for pausing,
resuming or removing several at once.

Press `n` anywhere to open the add dialog.

### Removing a download, and its bytes

aria2 never deletes anything itself, so a removed download used to leave its part
file and `.aria2` control file on disk forever. Now:

- **An unfinished download** — cancelling it takes the part file with it. There is
  nothing to ask: a half-written file is only ever rubbish.
- **A finished download** — you are asked once, because its file is the point:
  *keep file* removes only the row, *delete file* removes both.

Deletion is confined to the download's own directory and the configured download
directory, only ever touches the paths aria2 reported for that download plus
their `.aria2` control files, and refuses anything that is not a regular file.
Emptied folders left by a multi-file torrent are pruned.

### The same UI on the DankBar

If you run [DankMaterialShell](https://danklinux.com), `dms-plugin/` is the whole
web UI as a DMS plugin: a download icon on the bar showing live speed, clicked to
open a panel with Downloads, Rules and Settings (the event log folds away at the
bottom of Settings). It is a second front-end onto this daemon —
same `/api` endpoints, same `/api/events` stream — so the browser and the bar can
be open at once. Right-clicking the icon gives quick actions (pause/resume all,
purge, add from clipboard), and the panel can be detached into an ordinary
window that survives a click elsewhere.

```sh
ln -s "$PWD/dms-plugin" ~/.config/DankMaterialShell/plugins/aria2cManager
dms ipc call plugins enable aria2cManager      # then add it in Settings -> DankBar
dms ipc call aria2c toggle                     # bind this to a key if you like
dms ipc call aria2c toggleWindow               # ...or this, for the standalone window
```

See [dms-plugin/README.md](dms-plugin/README.md) for settings, IPC and hacking notes.

## 6. HTTP API

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
| `DELETE` | `/api/download/{gid}` | remove (`?force=&purge=&delete_files=`) — `delete_files` also deletes what it wrote |
| `POST` | `/api/downloads/bulk` | one action across a chosen set (`{action, gids, delete_files, force}`) |
| `POST` | `/api/global/pause-all\|resume-all\|purge\|save-session` | queue-wide commands |
| `GET`/`POST` | `/api/global/options` | read/write global aria2 options |
| `GET`/`POST` | `/api/rules` | read/replace rules; `POST /api/rules/{name}/toggle` |
| `GET` | `/api/aria2/status`, `POST /api/aria2/restart` | aria2c process supervision |
| `GET`/`POST` | `/api/config` | read the config / change `web_ui`, `poll_interval`, `poll_interval_idle` |
| `POST` | `/api/restart` | restart the manager itself (needs `Restart=always`) |
| `GET` | `/api/history` | finished downloads recorded across restarts (`?limit=&status=`) |
| `POST` | `/api/history/readd` | queue a past download again (`{key}`) |
| `POST` | `/api/history/remove`, `/api/history-clear` | forget one entry / all of them |
| `POST` | `/api/intake/add` | lenient intake used by the extension (alias: `/api/userscript/add`) |
| `GET` | `/api/intake/ping` | readiness probe for the extension (alias: `/api/userscript/ping`) |

aria2 errors come back as HTTP 502 with the aria2 message; if aria2c is not
running at all, commands return 503 explaining why rather than a bare 500.

## 7. Security

There is **no authentication**, by design — the server binds `127.0.0.1` only,
and CORS is open because the extension posts from arbitrary page origins. Do not
bind it to `0.0.0.0`: anything that can reach the port can queue downloads and
read your download list. The manager warns on startup if you do.

The aria2 RPC secret is generated randomly on first run and stored at
`~/.local/share/aria2c-manager/rpc-secret` with `0600` permissions (a secret you
set explicitly in `config.yaml` is used as-is instead). It is kept on disk rather
than regenerated per run for a functional reason: without it, a new manager cannot
authenticate to an aria2c left over from a previous run, so that process could
neither be adopted nor asked to stop. `/api/config` redacts it.

## 8. Tests

The suite runs the whole stack against a fake aria2 RPC server, so **no aria2c
installation is required** to run it:

```bash
python3 tests/test_manager.py     # the whole manager suite
```

It covers config merging and persistence, the aria2c command line, the REST and
SSE surface, adding/pausing/removing/repositioning, global options, the
browser intake (including that a `../../escape.iso` filename is reduced to a
basename), managed-mode process supervision (spawn → SIGKILL → automatic
restart → clean shutdown), the orphan cases above (SIGHUP exits with code 0 and
leaves no aria2c; a SIGKILL'd manager's orphan is adopted by the next run and
stopped cleanly; a foreign listener is reported and never killed), and — the
interesting one — that the stall-recovery
rule really does pause and resume a download whose speed drops, while leaving a
healthy download untouched.

Other tools:

```bash
python3 tests/fake_aria2.py --port 6800     # fake aria2 you can point the manager at
python3 -m aria2c_manager --no-aria2        # ...then attach to it

# Render the UI to a self-contained HTML file (screenshot-able offline)
python3 tests/render_ui.py --base http://127.0.0.1:6810 --tab downloads --expand \
    --out /tmp/ui.html
```

`tests/fake_aria2.py` seeds a download that deliberately stalls after 4 seconds,
which is the quickest way to watch a rule fire without waiting for a real server
to misbehave.

## 9. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `aria2c binary 'aria2c' not found in PATH` | install aria2, or set `aria2.binary` to a full path |
| `aria2c exited during startup` | usually an invalid option in `aria2.options`; check `~/.local/share/aria2c-manager/aria2.log`, or run `--print-argv` |
| The extension says "cannot reach the manager" | manager not running, or the server URL in its Settings does not match your port |
| A download still lands in the browser | interception is off in Settings, the host is on the blocklist, or it is a `blob:`/`data:` URL aria2 cannot fetch |
| The extension vanished after restarting Firefox | temporary add-ons do not survive a restart — see §3 |
| Unfinished downloads did not come back after a restart | they resume from `aria2.session_file` (written every 30 s and on clean shutdown) plus the `.aria2` file beside the partial download — check both still exist |
| Completed downloads vanished from the list | aria2 never persists finished downloads; the manager's own History filter keeps them (`history.file`) |
| An action reports "aria2c is not running" while it clearly is | fixed in this build: aria2 answers ordinary errors with HTTP 400 and a JSON body, which was being read as a dead daemon. Errors now show aria2's real message |
| After closing the terminal, a rerun says "aria2c exited during startup" | fixed in this build: SIGHUP now shuts down cleanly, and any leftover aria2c is adopted or reclaimed. If you still see it, something unrelated holds the port — check with `ss -lptn "sport = :6800"` |
| A rule fires over and over | raise `cooldown_seconds` / `min_age_seconds`, or lower `max_triggers` |
| A rule fires on a download that just started | fixed in this build: `min_age_seconds` now counts from when it started transferring, not from when it was queued |
| Speed shown does not match the bytes arriving | aria2's figure is a moving average — see §4. The row shows the measured figure alongside it when they diverge |
| "Clear history" appears to do nothing | fixed in this build: dismissals are remembered, *and* aria2's own finished results are purged so the rows also leave the Downloads list |
| A stall fix makes the download swap places with the next one | fixed in this build: the action reclaims its concurrency slot. See §4 |

## Layout

```
aria2c_manager/
  __main__.py     CLI entrypoint
  config.py       YAML config: defaults, merge, persistence
  rpc.py          async aria2 JSON-RPC client (HTTP transport)
  supervisor.py   spawn / health-check / restart / shut down aria2c
  state.py        1 Hz poller, snapshot normalisation, SSE fan-out
  rules.py        custom download actions
  api.py          FastAPI routes
  static/         web UI (no build step, no dependencies)
dms-plugin/       DankMaterialShell bar widget (same API, QML front-end)
extension/        browser extension (Firefox + Chromium, MV3)
tests/            fake aria2, suites, UI render harness
systemd/          user service unit
```
