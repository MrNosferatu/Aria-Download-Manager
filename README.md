# Aria Download Manager

A background download server built on aria2c, driven from a browser extension
(which hands it the browser's own downloads and carries the full manager UI) and,
optionally, a DankMaterialShell bar widget. Every aria2 capability that matters
for downloading — queueing, splitting a file into parts, parallel downloads,
parallel connections per server, speed limits, BitTorrent — is exposed in the UI,
and a small rules engine can take automatic action on a download when it
misbehaves (for example: *speed under 50 KiB/s for 3 seconds → pause and resume*).

```
Extension ──native messaging──→ native host ──┐
                                              ├─ Unix socket ─→ manager ──JSON-RPC──→ aria2c
DankBar widget (optional) ────────────────────┘                   │
                                                                  └── rules engine (1 Hz tick)
```

The manager listens on nothing but a Unix socket
(`$XDG_RUNTIME_DIR/aria-download-manager.sock`). A socket is not network traffic, so a
VPN or proxy built into the browser cannot route it away the way it can with
`127.0.0.1` — and there is no port for anything else to reach. The only TCP in
the picture is the manager's own link to aria2c's RPC on loopback.

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

The Python side needs `fastapi`, `aiohttp` and `PyYAML`, which are already
present on this machine's system Python. On another machine:

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
```

There is no web server: FastAPI only routes the requests that arrive on the
socket, in-process. `.torrent` uploads travel as base64 JSON, so no
`python-multipart` either.

## 2. Run

```bash
cp config.example.yaml config.yaml     # optional; defaults work as-is
./run.sh                               # or: python3 -m aria_download_manager
```

```
Aria Download Manager 1.0.0
  socket     /run/user/1000/aria-download-manager.sock
  config     /home/you/GitHub/Aria2C/config.yaml
```

Useful flags:

| Flag | Purpose |
| --- | --- |
| `--no-aria2` | attach to an aria2c you already run instead of spawning one |
| `--print-argv` | show the exact aria2c command line that would be used |
| `--print-config` | show the effective config after merging defaults |
| `-c FILE` | use a different config file |
| `--install-native-host` | register the extension's IPC bridge with Firefox and Chromium browsers (see §3) |

### Run it in the background at login

```bash
mkdir -p ~/.config/systemd/user
cp systemd/aria-download-manager.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now aria-download-manager
systemctl --user status aria-download-manager
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

`extension/` is the browser half: it takes over the browser's own downloads,
hands them here, and carries the full manager UI. Firefox is the supported
target; the same directory also loads in Chromium.

**Install it** — pick one:

| | How | Survives a browser restart |
| --- | --- | --- |
| From AMO | Once published, one click from the add-on's page | yes, and auto-updates |
| Signed file | `./extension/build.sh sign unlisted` → open the `.xpi` in Firefox (`about:addons` → gear → *Install Add-on From File*) | yes |
| Unpacked, Firefox | `about:debugging#/runtime/this-firefox` → *Load Temporary Add-on* → `extension/manifest.json` | no — gone on restart |
| Unpacked, Chromium | `chrome://extensions` → *Developer mode* → *Load unpacked* → `extension/` | yes |

Signing needs a free AMO API key; `extension/store/listing.md` has the
submission material, and `extension/build.sh` wraps the packaging.

**Register the IPC bridge once.** The extension reaches the manager through
native messaging: the browser starts a small host process
(`aria_download_manager/native_host.py`), which relays to the manager's Unix socket.
Nothing goes over the network, so an in-browser VPN cannot get in the way.

```bash
python3 -m aria_download_manager --install-native-host
```

That writes a launcher to `~/.local/share/aria-download-manager/` and a host manifest
for Firefox (`~/.mozilla/native-messaging-hosts/`) and for every Chromium-family
browser that has the extension loaded unpacked from this checkout — the
extension id is read from the browser profile. For a packed Chromium install,
pass `--chrome-extension-id ID`. Restart the browser afterwards. Re-run it if you
move the checkout or change `server.socket`. Browsers installed as Flatpak or
Snap cannot start host processes outside their sandbox, so they cannot use the
extension; use a native package.

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
| Toolbar popup | live speed, active/queued counts, progress of what is running, a box to paste a URL or magnet, and a per-site *skip auto-capture* switch, and the button that opens the full manager (§5) |
| Badge | number of active downloads, `!` when the manager is unreachable |
| Right-click a link / image / video / audio | send just that one |
| Right-click a page | send the page URL, or every downloadable link on it |
| Right-click a selection | send every link inside it |
| Click capture | left-click on a magnet, or on a link the browser would *render* rather than download, sends it here instead |
| Alt+click | sends any link, even with capture off |
| Settings page | connection test, save directory, add-paused, minimum size, which extensions count, per-host blocklist, notification style |

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

## 5. The manager page

The extension carries the whole manager UI: *open the full manager* in its
toolbar popup opens it in a tab (or brings an open one forward). It talks to the
manager through the native-messaging host and the socket, like everything else
in the extension. The files are `extension/manager/`.

The manager polls aria2 once a second, and backs off to `poll_interval_idle`
whenever nothing is downloading *and* nothing is subscribed to the live stream,
so an idle manager with no windows open barely ticks. Any command wakes it
immediately.

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

**Speeds and sizes** — every speed limit, part size, cache size and the rules'
speed threshold is a number plus a unit (B/s · KiB/s · MiB/s · GiB/s, or
B · KiB · MiB · GiB), shown in the most readable unit — `12 MiB/s`, not
`12582912`. Changing the unit reinterprets the number you typed, shorthand like
`12M` typed into the box works too, and an empty speed limit means no limit.
Values are still stored as bytes, which is what aria2 and `config.yaml` get.
The DankBar widget and the extension's minimum-size setting use the same
control.

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

### The same UI on the DankBar (optional)

If you run [DankMaterialShell](https://danklinux.com), `dms-plugin/` is the same
manager as a DMS plugin: a download icon on the bar showing live speed, clicked to
open a panel with Downloads, Rules and Settings (the event log folds away at the
bottom of Settings). It is a second front-end onto this daemon over the same
socket, so the extension's manager page and the bar can be open at once. Right-clicking the icon gives quick actions (pause/resume all,
purge, add from clipboard), and the panel can be detached into an ordinary
window that survives a click elsewhere.

```sh
ln -s "$PWD/dms-plugin" ~/.config/DankMaterialShell/plugins/ariaDownloadManager
dms ipc call plugins enable ariaDownloadManager      # then add it in Settings -> DankBar
dms ipc call ariaDownloadManager toggle                     # bind this to a key if you like
dms ipc call ariaDownloadManager toggleWindow               # ...or this, for the standalone window
```

See [dms-plugin/README.md](dms-plugin/README.md) for settings, IPC and hacking notes.

## 5b. Downloading video from a page

A modern player never puts a downloadable URL in the page. It fetches an HLS or
DASH manifest and feeds segments to the `<video>` element through Media Source
Extensions, so `video.src` is a `blob:` handle to a buffer in memory — nothing a
download manager can fetch.

What is still visible is the manifest going past on the network, and a manifest
is a published list of exactly the qualities the site will serve. So the
extension watches requests rather than the DOM: when it sees a manifest or a
media file for a tab, it puts a small **Download** button over the player. The
button asks the manager to read that manifest, and offers what it found.

```
page fetches manifest ──► extension sniffs it (webRequest, observation only)
                            │
                            └─► /api/media/probe        → 1080p60 / 720p / 360p
                                     │  (with the page's cookies, so a
                                     │   members-only stream probes correctly)
                                     └─► /api/media/download
                                            ├─ progressive file → aria2, as usual
                                            └─ HLS/DASH → ffmpeg fetches the
                                               segments and muxes them into one
                                               .mp4, reported as a media job
```

Stream jobs appear in every state frame under `media`, so both front-ends see
them alongside ordinary downloads.

**Requires ffmpeg** for segmented streams — it is what fetches the parts and
joins them. A progressive `.mp4` needs nothing extra and goes to aria2 like any
other download.

**DRM is out of reach.** Netflix, Prime and friends encrypt segments with
Widevine, and the keys live in a module the browser will not hand over. That is
a hard boundary, not a missing feature.

## 6. API (over the socket)

The protocol is newline-delimited JSON: send
`{"id": 1, "method": "GET", "path": "/api/state"}` and get back
`{"id": 1, "status": 200, "body": {...}}`. `{"method": "SUBSCRIBE"}` starts the
live frames on that connection as `{"event": "state", "data": {...}}` lines
(`state`, `event`, `backlog`, `shutdown`), and `UNSUBSCRIBE` stops them. Requests
on one connection are answered concurrently.

```bash
echo '{"id":1,"method":"GET","path":"/api/intake/ping"}' \
  | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/aria-download-manager.sock
```

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/state` | latest snapshot, including aria2c's process status under `aria2` |
| `GET` | `/api/log` | recent events and rule triggers |
| `POST` | `/api/downloads` | add URIs (`{uris, options, position, paused, mirrors}`) |
| `POST` | `/api/downloads/file` | add a base64 `.torrent`/`.metalink` |
| `GET` | `/api/download/{gid}` | detail: status, files, uris, options, servers, peers, piece map |
| `POST` | `/api/download/{gid}/pause\|resume\|retry` | per-download commands |
| `POST` | `/api/download/{gid}/options\|position\|select` | change options, queue position, selected files |
| `DELETE` | `/api/download/{gid}` | remove (`?force=&purge=&delete_files=`) — `delete_files` also deletes what it wrote |
| `POST` | `/api/downloads/bulk` | one action across a chosen set (`{action, gids, delete_files, force}`) |
| `POST` | `/api/media/probe` | read a stream manifest and list its qualities (`{url, cookie, referer, user_agent}`) |
| `POST` | `/api/media/download` | queue a chosen quality — aria2 for a file, ffmpeg for a stream |
| `POST` | `/api/global/pause-all\|resume-all\|purge` | queue-wide commands |
| `GET`/`POST` | `/api/global/options` | read/write global aria2 options |
| `GET`/`POST` | `/api/rules` | read/replace rules; `POST /api/rules/{name}/toggle` |
| `POST` | `/api/aria2/restart` | restart aria2c |
| `GET` | `/api/config` | the effective config (RPC secret redacted) |
| `POST` | `/api/restart` | restart the manager itself (needs `Restart=always`) |
| `GET` | `/api/history` | finished downloads recorded across restarts (`?limit=&status=`) |
| `POST` | `/api/history/readd` | queue a past download again (`{key}`) |
| `POST` | `/api/history/remove`, `/api/history-clear` | forget one entry / all of them |
| `POST` | `/api/intake/add` | lenient intake used by the extension |
| `GET` | `/api/intake/ping` | readiness probe: version, whether aria2c is up, the socket path |

aria2 errors come back as status 502 with the aria2 message; if aria2c is not
running at all, commands return 503 explaining why rather than a bare 500.

## 7. Security

There is **no authentication**, by design, and nothing that needs it: the manager
opens no network port at all. Its socket is created with mode `0600` inside
`$XDG_RUNTIME_DIR` (itself `0700`), so only your user can connect, and no website
can reach it through your browser.

The aria2 RPC secret is generated randomly on first run and stored at
`~/.local/share/aria-download-manager/rpc-secret` with `0600` permissions (a secret you
set explicitly in `config.yaml` is used as-is instead). It is kept on disk rather
than regenerated per run for a functional reason: without it, a new manager cannot
authenticate to an aria2c left over from a previous run, so that process could
neither be adopted nor asked to stop. `/api/config` redacts it.

## 8. Tests

The suite runs the whole stack against a fake aria2 RPC server, so **no aria2c
installation is required** to run it:

```bash
python3 tests/test_manager.py     # the whole manager suite
python3 tests/test_ipc.py         # Unix socket, event stream, native-messaging host
```

It covers config merging and persistence, the aria2c command line, the API and
live stream over the socket (and that no TCP port is opened),
adding/pausing/removing/repositioning, global options, the
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
python3 -m aria_download_manager --no-aria2        # ...then attach to it

# Render the manager page from a running manager to a self-contained HTML file
# (opens offline, screenshot-able headless)
python3 tests/render_ui.py --tab downloads --expand --out /tmp/ui.html
```

`tests/fake_aria2.py` seeds a download that deliberately stalls after 4 seconds,
which is the quickest way to watch a rule fire without waiting for a real server
to misbehave.

## 9. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `aria2c binary 'aria2c' not found in PATH` | install aria2, or set `aria2.binary` to a full path |
| `aria2c exited during startup` | usually an invalid option in `aria2.options`; check `~/.local/share/aria-download-manager/aria2.log`, or run `--print-argv` |
| The extension says "the native host is not installed" | run `python3 -m aria_download_manager --install-native-host`, then restart the browser |
| The extension or widget says "Aria Download Manager is not running (no socket at …)" | start the manager; if `server.socket` is set, re-run `--install-native-host` and set the widget's *Manager socket* to match |
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
aria_download_manager/
  __main__.py     CLI entrypoint
  config.py       YAML config: defaults, merge, persistence
  rpc.py          async aria2 JSON-RPC client (HTTP transport)
  supervisor.py   spawn / health-check / restart / shut down aria2c
  state.py        1 Hz poller, snapshot normalisation, live-stream fan-out
  rules.py        custom download actions
  api.py          the API: FastAPI routes, run in-process (no web server)
  ipc.py          the Unix socket: newline-delimited JSON into those routes
  native_host.py  native-messaging bridge for the extension (stdlib only)
dms-plugin/       DankMaterialShell bar widget (optional; QML front-end over the socket)
extension/        browser extension (Firefox + Chromium, MV3)
  manager/        the full manager page, opened from the popup
  lib/link.js     the native-messaging connection, shared by the background and the page
tests/            fake aria2, suites, UI render harness
systemd/          user service unit
```
