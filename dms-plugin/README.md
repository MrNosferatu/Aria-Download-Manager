# aria2c manager — DankMaterialShell plugin

The web UI, ported to a [DankMaterialShell](https://danklinux.com) bar widget: a
download icon on the DankBar that opens a window with four tabs — Downloads,
Settings, Rules and Log.

The plugin does **not** download anything itself. It is a second front-end onto
the same `aria2c-manager` daemon the web UI talks to (`/api/*` over HTTP, plus
the `/api/events` SSE stream), so both can be open at once and stay in sync.

```
DankBar pill ──► Aria2Service (singleton) ──► http://127.0.0.1:6810
                   │  curl -sN /api/events  (one stream, all monitors)
                   └─ XHR for every command and lazily loaded section
```

## Install

The plugin lives in this repo and is symlinked into the DMS plugin directory, so
`git pull` updates it in place:

```sh
ln -s "$PWD/dms-plugin" ~/.config/DankMaterialShell/plugins/aria2cManager
dms ipc call plugins enable aria2cManager
```

Then add it to the bar: **Settings → DankBar → Widgets**, add *aria2c Manager*
to a section (or edit `barConfigs[].rightWidgets` in
`~/.config/DankMaterialShell/settings.json` and add
`{"id": "aria2cManager", "enabled": true}`).

Start the daemon first — `./run.sh`, or the systemd user unit in `systemd/`.
Until it answers, the pill shows `offline` and the window explains where it
looked.

## Settings

**Settings → Plugins → aria2c Manager**:

| Setting | Default | What it does |
| --- | --- | --- |
| Manager host / port | `127.0.0.1` / `6810` | Must match `server.host`/`server.port` in `config.yaml` |
| Bar label | Download speed | Speed, active count, or icon only |
| Popout width / content height | 640 / 540 | Size of the manager window |
| Toast on events | off | Toast when a download finishes or the manager logs an error |

## IPC

```sh
dms ipc call aria2c toggle              # show/hide the window
dms ipc call aria2c tab rules           # switch tab: downloads settings rules log
dms ipc call aria2c add <url>           # queue a URL with default options
dms ipc call aria2c status              # one-line summary
dms ipc call aria2c streamInfo          # event-stream health (silence, restarts)
dms ipc call aria2c pauseAll            # / resumeAll
```

Bind `toggle` to a key in your compositor for a hotkey-driven download manager —
in niri:

```kdl
binds {
    Mod+D { spawn "dms" "ipc" "call" "aria2c" "toggle"; }
}
```

## What each tab does

- **Downloads** — filter chips with live counts, name filter, and an inline Add
  panel (URLs, directory, rename, plus connections/split/referer/cookie/headers
  and a `.torrent`/`.metalink` path under *More options*). Each row expands into
  the same detail the web UI shows: piece map, paths, per-download options,
  file selection, live connections, URLs and peers. The **History** chip lists
  what the manager recorded, with re-add and forget.
- **Settings** — a **Manager** section (Web UI switch + *Restart manager*), then the grouped aria2 global options, a filter box, an *All options
  (advanced)* section built from whatever aria2 reports, and the aria2c process
  card with a restart button. Edited fields are dot-marked until saved.
- **Rules** — the rule cards, editable field by field or as raw JSON, plus the
  speed-source selector and recent triggers. The master switch is the toggle in
  the window header.
- **Log** — the live event stream, click a line to copy it.

Setup material — how to load the extension, the intake endpoints — lives in the
web UI's Extension tab instead, since it is read once. The header's
*open in browser* button goes there.

## Hacking

QML files are compiled once per shell session. `dms ipc call plugins reload
aria2cManager` re-runs the widget, but **changes to
`services/Aria2Service.qml` (or anything already compiled) only take effect
after `systemctl --user restart dms`** — reload alone will keep serving the
cached component and the old singleton.

Errors inside plugin QML are not printed by default. To see them:

```sh
qs log -r "*=true" -t 100000 "$(ls -t /run/user/$UID/quickshell/by-id/*/log.qslog | head -1)" | grep -i aria2
```

Two QML traps that fail *silently* here, both hit during this port: declaring
`property var data` or `property string state` on an `Item` collides with
built-ins and the whole component fails to load with no message.

## Layout

```
dms-plugin/
├── plugin.json              manifest (composite: widget + settings)
├── qmldir                   registers the Aria2Service singleton
├── Aria2Widget.qml          bar pill, control-center tile, popout host
├── Aria2Settings.qml        Settings → Plugins page
├── services/Aria2Service.qml   SSE stream, REST calls, shared state, IPC
├── lib/Fmt.js               byte/speed/ETA formatting shared with the web UI
└── components/              popout shell, one file per tab, row delegates
```
