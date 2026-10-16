# Aria Download Manager — DankMaterialShell plugin

The manager UI, as a [DankMaterialShell](https://danklinux.com) bar widget: a
download icon on the DankBar that opens a panel with three tabs — Downloads,
Actions and Settings. Left-click for the bar popout, right-click for quick
actions, and the popout's *open in window* button detaches the whole thing into
an ordinary window that stays put while you work elsewhere.

The plugin does **not** download anything itself. It is a second front-end onto
the same Aria Download Manager daemon the browser extension talks to, over the same
Unix socket, so the extension's manager page and the widget can be open at once
and stay in sync.

```
DankBar pill ──► Aria2Service (singleton) ──► $XDG_RUNTIME_DIR/aria-download-manager.sock
                   │  one Quickshell Socket, newline-delimited JSON
                   ├─ SUBSCRIBE while a panel is open (live frames, all monitors)
                   └─ request/reply by id for every command and lazily loaded section
```

Nothing goes through the network stack, so a VPN or proxy cannot get between the
widget and the manager.

## Install

The plugin lives in this repo and is symlinked into the DMS plugin directory, so
`git pull` updates it in place:

```sh
ln -s "$PWD/dms-plugin" ~/.config/DankMaterialShell/plugins/ariaDownloadManager
dms ipc call plugins enable ariaDownloadManager
```

Then add it to the bar: **Settings → DankBar → Widgets**, add *Aria Download Manager*
to a section (or edit `barConfigs[].rightWidgets` in
`~/.config/DankMaterialShell/settings.json` and add
`{"id": "ariaDownloadManager", "enabled": true}`).

Start the daemon first — `./run.sh`, or the systemd user unit in `systemd/`.
Until it answers, the pill shows `offline` and the window explains where it
looked.

## The bar pill

- **Icon** — `download` when idle, `downloading` (in the accent colour) while
  something runs, `error` if aria2c is down, a dimmed `cloud_off` when the
  manager is unreachable. Idle, it takes the bar's own widget colours.
- **Progress line** — a thin bar under the icon shows how far along all running
  downloads are together (sized downloads only; seeders are left out).
- **Red dot** — at least one download failed; it clears with the failed rows.
- **Label** — the speed, held at a fixed width so the bar does not jitter;
  idle, `N queued` / `N paused`, or nothing. On a vertical bar it shrinks to
  `12M` or the active count.

## Settings

**Settings → Plugins → Aria Download Manager**:

| Setting | Default | What it does |
| --- | --- | --- |
| Manager socket | `$XDG_RUNTIME_DIR/aria-download-manager.sock` | Must match `server.socket` in `config.yaml` (blank on both sides = default) |
| Bar label | Download speed | Speed, active count, or icon only |
| Show when idle | on | Off hides the pill while nothing is downloading, queued or failed |
| Clicking the bar icon opens | Bar popout | Whether left click opens the bar popout or goes straight to the standalone window |
| Popout width / content height | 640 / 540 | Size of the bar popout (the window is resized by dragging it) |
| Bar refresh interval | 3 s | How far behind the pill may lag a download that starts while the panel is closed |
| Always stream | off | Keep one long-lived event connection open so the pill is never behind at all |
| Notify on events | off | Toast when a download finishes or the manager logs an error |

## IPC

```sh
dms ipc call ariaDownloadManager toggle              # show/hide the bar popout
dms ipc call ariaDownloadManager toggleWindow        # show/hide the standalone window
dms ipc call ariaDownloadManager tab actions         # switch tab: downloads actions settings (rules = actions)
dms ipc call ariaDownloadManager tab log             # settings, with the event log unfolded
dms ipc call ariaDownloadManager add <url>           # queue a URL with default options
dms ipc call ariaDownloadManager status              # one-line summary
dms ipc call ariaDownloadManager streamInfo          # event-stream health (silence, restarts)
dms ipc call ariaDownloadManager pauseAll            # / resumeAll
```

Bind `toggle` to a key in your compositor for a hotkey-driven download manager —
in niri:

```kdl
binds {
    Mod+D { spawn "dms" "ipc" "call" "aria2c" "toggle"; }
}
```

## Feedback

A success ("History cleared", "Actions saved", "Copied") shows as a small pill
that rises into the bottom of the panel, holds for a moment, and sinks away;
click it to dismiss early. It never becomes a shell notification. Only errors
and the optional *Notify on events* toasts go through the shell's
notifications.

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

**On tiling compositors** the window is an ordinary `xdg_toplevel` under DMS's
own app-id, `com.danklinux.dms`, so whatever rule you have for DMS windows
applies to it. In niri, this floats it and tiles the folder picker — which is
backwards if you would rather have the manager in the layout and the dialog
floating over it:

```kdl
window-rule {
    match app-id=r#"^com\.danklinux\.dms$"# title=r#"^Aria Download Manager$"#
    open-floating false
}
window-rule {
    // Note the suffix: the portal's real app-id is xdg-desktop-portal-gtk,
    // so a rule anchored at ^xdg-desktop-portal$ never matches it.
    match app-id=r#"^xdg-desktop-portal"#
    open-floating true
}
```

## Quick actions

Right-clicking the bar icon opens a menu that does the common things without
opening the manager at all:

- **Open in window** and **Add link from clipboard** (needs `wl-clipboard`; the
  clipboard has to hold an `http`/`https`/`ftp`/`sftp`/`magnet` URL)
- **Pause all**, **Resume all**, **Clear finished** — each showing its count
- **Turn rules on/off**
- **Restart aria2c**

Entries that cannot do anything right now are greyed out: purge with nothing
finished, and anything at all while the manager is offline. The top of the menu
repeats the pill's status in words.

## What each tab does

- **Downloads** — filter chips with live counts (including *All* and
  *Done*), a search box, and an inline Add panel with a *Simple / Advanced*
  switch: Simple is links, folder and *Start paused*; Advanced adds rename,
  connections, parts, limits, referer, cookies, headers, proxy, checksum, queue
  position and a `.torrent`/`.metalink` path. *Next* always reviews before
  anything starts: plain links are checked and shown with their real name,
  size, type and resumability, with the folder (preset menu, or the chooser)
  and *Download* / *Download later*; a torrent (magnet, `.torrent` link or
  file) is added held, and once its file list arrives the panel shows its
  files with priorities and its options, with *Apply and start* or *Cancel*.
  Each row expands into
  the same detail the extension's manager page shows: piece map, paths, per-download options,
  file selection, live connections, URLs and peers. The **History** chip lists
  what the manager recorded, with re-add and forget.
- Speeds and sizes (limits, part size, disk cache, a rule's speed threshold) are
  a number plus a unit picker, shown as `12 MiB/s` rather than bytes — the same
  control as the extension's manager page.
- **Actions** — one card per automatic action (the `rules` in `config.yaml`),
  editable field by field or as raw JSON, plus the *Speed by* selector (Hybrid,
  Write speed, Reported speed) and recent triggers. The master switch is the
  *Actions* toggle in the window header.
- **Settings** — the same *Simple / Advanced* switch as the manager page.
  Simple is one card with the seven options that decide how a download behaves
  (folder, downloads at once, connections per server, parts, the two speed
  limits, resume). Advanced adds a search box, the grouped aria2 options, an
  *Every aria2 option* fold built from whatever aria2 reports, the aria2c
  process card (with *Restart manager* and *Restart aria2c*), and the event log.
  Edited fields are dot-marked until saved, and the choice is remembered.

The **event log** is no longer a tab of its own. It is diagnostic material
rather than something to watch, so it folds away at the bottom of *Settings*,
under the aria2c process card it usually explains — click the header to unfold
it, or run `dms ipc call ariaDownloadManager tab log`, which unfolds it and scrolls down to
it. Same live stream as before: click a line to copy it.

### What "All" holds

The chips count what aria2 is currently holding, and **All** is now labelled
with that total. Worth knowing: aria2 forgets stopped downloads when it is
purged or restarted, so a file you finished yesterday will not be under *All*
or *Done* today — the **History** chip is the durable record, and it
survives restarts because the manager keeps it itself.

### Moved or deleted files

A finished download whose file is no longer on disk is marked **File missing**,
in both the download list and History, and its *open file* button goes away so
it cannot launch something that is not there. The manager checks the path when
it reports a finished download, so moving or deleting a file is reflected within
a tick — there is nothing to refresh.

## Hacking

QML files are compiled once per shell session. `dms ipc call plugins reload
ariaDownloadManager` re-runs the widget, but **changes to
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
├── services/Aria2Service.qml   socket connection, event stream, API calls, shared state, IPC
├── lib/Fmt.js               byte/speed/ETA formatting shared with the extension's manager page
├── lib/Actions.js           the global actions, described once for every surface
├── lib/Layout.js            layout constants more than one surface has to agree on
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
