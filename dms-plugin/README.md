# aria2c manager — DankMaterialShell plugin

The web UI, ported to a [DankMaterialShell](https://danklinux.com) bar widget: a
download icon on the DankBar that opens a panel with four tabs — Downloads,
Settings, Rules and Log. Left-click for the bar popout, right-click for quick
actions, and the popout's *open in window* button detaches the whole thing into
an ordinary window that stays put while you work elsewhere.

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
| Clicking the bar icon | Bar popout | Whether left click opens the bar popout or goes straight to the standalone window |
| Popout width / content height | 640 / 540 | Size of the bar popout (the window is resized by dragging it) |
| Toast on events | off | Toast when a download finishes or the manager logs an error |

## IPC

```sh
dms ipc call aria2c toggle              # show/hide the bar popout
dms ipc call aria2c toggleWindow        # show/hide the standalone window
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

## The standalone window

The bar popout is a layer-shell surface: it closes the moment you click
anything else, which is wrong for a download manager you want to watch while
doing something else. The *open in window* button in the popout header hands the
same content to a real window — movable, resizable, maximisable, and unbothered
by clicks elsewhere. Its counterpart in the window's title bar docks it back
into the bar.

Set **Clicking the bar icon → Standalone window** to skip the popout entirely,
or bind the window to a key:

```kdl
binds {
    Mod+D { spawn "dms" "ipc" "call" "aria2c" "toggleWindow"; }
}
```

One window is shared by the whole shell — on a multi-monitor setup the first
bar to load claims it, and the others route their requests there.

## Quick actions

Right-clicking the bar icon opens a menu that does the common things without
opening the manager at all:

- **Open in window** and **Add URL from clipboard** (needs `wl-clipboard`; the
  clipboard has to hold an `http`/`https`/`ftp`/`sftp`/`magnet` URL)
- **Pause all**, **Resume all**, **Purge finished** — each showing its count
- **Enable/Disable rules**, **Open web UI**
- **Restart aria2c**

Entries that cannot do anything right now are greyed out: purge with nothing
finished, anything at all while the manager is offline, and **Open web UI**
whenever `server.web_ui` is off — that endpoint serves a JSON hint rather than
the UI, so the button would only ever open a page explaining itself. The menu
marks it *Web UI is off*; the same button in the popout and window headers is
dimmed with a tooltip saying where to turn it on. The top of the menu repeats
the pill's status in words.

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
├── Aria2Widget.qml          bar pill, control-center tile, popout/window host
├── Aria2Settings.qml        Settings → Plugins page
├── services/Aria2Service.qml   SSE stream, REST calls, shared state, IPC
├── lib/Fmt.js               byte/speed/ETA formatting shared with the web UI
├── lib/Actions.js           the global actions, described once for every surface
└── components/
    ├── Aria2Popout.qml      the manager itself — hosted by both the popout and the window
    ├── Aria2Window.qml      standalone window: title bar, window controls, the popout inside
    ├── ManagerActions.qml   header buttons shared by the popout and the window
    ├── QuickMenu.qml        the right-click menu, QuickMenuRow.qml one line of it
    └── ...                  one file per tab, plus the row delegates
```

`lib/Actions.js` holds the global actions — endpoints, icons, wording — because
the header row and the quick menu both render them and would otherwise drift.
Only the static half lives there: whether an action is enabled, and the count it
shows, are read off the service in QML, where property capture keeps the
bindings live.
