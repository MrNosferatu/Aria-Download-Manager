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
Until it answers, the bar icon is a dimmed `cloud_off` and the panel explains
where it looked, with the socket path to copy and a *Retry now* button.

## The bar icon

The icon says what is happening; words appear only when something needs them.

| State | Icon | Label |
| --- | --- | --- |
| Downloading | `downloading`, ring = overall progress | speed (or count, per *Bar label*) |
| Paused / waiting only | `pause_circle` / `schedule`, muted | `3 paused` / `2 queued` |
| Finished while the panel was closed | `download` with a dot | — (the dot clears when the panel opens) |
| Idle | `download` | — |
| aria2c not running | `error`, red | `aria2c down` |
| Manager offline | `cloud_off`, dimmed | — |

The ring is the running downloads' completed bytes over their total; it stays
off while any of them has no size yet (a magnet still fetching its file list).
The speed label reserves the width of its widest form, so the bar does not
shift every second. *Count* mode shows running, then waiting (`2 +3`). On a
vertical bar the speed is split onto two lines, and idle shows nothing.

**Hover** the icon for a moment and a card says how it is going without a
click: `2 downloading · 62% · 3 min` and the two downloads furthest along;
`3 paused, 1 waiting`; `Nothing downloading` with what finished today; the
reason aria2c stopped; or the socket the widget tried. It is its own overlay
layer and takes no input, so it never gets between the pointer and the icon,
and a click hides it.

**Middle-click** the icon to pause everything that runs, or resume what is
waiting when nothing does — the same flip as the panel's header button, with
Undo in the panel.

**Hide when idle** (off by default) takes the icon off the bar while nothing is
running or waiting. It stays while offline, while aria2c is down, and while a
finished download is unseen.

## Settings

**Settings → Plugins → Aria Download Manager**:

| Setting | Default | What it does |
| --- | --- | --- |
| Manager socket | `$XDG_RUNTIME_DIR/aria-download-manager.sock` | Must match `server.socket` in `config.yaml` (blank on both sides = default). A dot beside it says whether the widget is connected; *Test* dials again |
| Label next to the icon | Speed | Speed, count, or none — shown only while something is happening |
| Progress ring | on | Overall progress as a ring around the bar icon |
| Hide when idle | off | Take the icon off the bar when nothing runs or waits |
| Click opens | Popout | Whether left click opens the bar popout or the standalone window |
| Popout size | 640 × 540 px | Two sliders, width and content height; the window is resized by dragging it |
| Bar refresh while closed | 3 s | How far behind the pill may lag a download that starts while the panel is closed |
| Always stream | off | Keep one long-lived event connection open so the pill is never behind at all |
| When a download finishes / When something fails | off | Toasts, set apart. A setup from before the split keeps its single `notify` choice for both |

The page is grouped (Connection, Bar, Popout & updates, Notifications) and has
a live preview of the bar icon that flips through Downloading, Paused, Idle and
Error with the settings above applied.

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

A success ("History cleared", "Actions saved", "Copied") shows as a small
inverse-coloured pill that rises into the bottom of the panel, holds for a
moment, and sinks away; click it to dismiss early. Anything reversible — pause
all, pause or resume one download, a bulk pause or resume — carries **Undo**
for five seconds. Clearing, removing and forgetting history do not: what they
drop is gone. It never becomes a shell notification.

Errors do go through the shell's notifications, in plain words: what failed
and why as the headline ("Couldn't add the download — the server says the
file isn't there (404)"), what to do and the original message in the details.
The common ones are recognised — 401/403/404, disk full, permission denied,
a link aria2 cannot fetch, a name that does not resolve, a timeout, a bad
checksum. DMS toasts cannot carry buttons, so a finished-download toast has no
*Open* / *Show in folder*.

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

**At 900 px and wider** the window uses its width: a rail on the left (*Add
download*, then All, Active, Queued, Paused, Done, Failed and History with
their counts, then Actions with "3 on" / "off" and Settings), the list in the
middle, where a click selects a download instead of unfolding it, and its
details in a pane on the right with *Pause*, *Folder* and remove on top. A
status bar at the bottom holds download and upload speed, what is left and
how long, aria2c's state and version, and whether automatic actions are on.
Actions show the list beside the open action's editor and its own trigger
history; Settings lists its sections on the left and jumps to each. When the
manager is offline the rail stays, so the window keeps its shape. Narrower
than 900 px, the window shows the popout's layout.

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

Right-clicking the bar icon opens a menu that shows what is happening before
what can be done:

- **Status** — `2 downloading`, speed and time left, an overall progress bar,
  and how many are waiting or finished since you last looked
- **Up to three downloads** — running first, then paused and waiting — each
  with its own pause / resume button
- **Pause all**, **Resume**, **Clear** — side by side, each with its count;
  pausing or clearing nothing is greyed out
- **Add link from clipboard**, previewing the link it would add (host and the
  end of the path, or the magnet's name) and greyed out when the clipboard
  holds no `http`/`https`/`ftp`/`sftp`/`magnet` link. It reads the clipboard
  with `wl-paste` when installed and DMS's own `dms cl paste` otherwise.
  **Open manager**, **Open in window**
- **Automatic actions** — a switch, and the menu stays open so it can be seen
  to move
- **Restart aria2c**, set apart at the bottom

When aria2c is down the menu leads with the error and a *Restart aria2c*
button, keeps the bulk buttons in place but off, and offers the event log.
When the manager is offline it is only the socket it tried, *Retry now* and
*Copy socket path*. More than three downloads end the list with
"+N more · Open manager".

## The panel

The tabs are one compact segmented strip; Actions carries "3 on" or "off".
On first open, before the manager has answered, the list shows skeleton rows
(after 300 ms, so a fast connect never flashes them).

Above the tabs: one *Pause all / Resume all* button that flips with the state,
*Clear finished* (greyed with nothing to clear), and *open in window*. Then the
stat strip — download speed as the headline with the last minute as a
sparkline, upload, and what is left with its time. The per-state counts are on
the Downloads filter chips. When aria2c is down a banner with its error,
*Restart aria2c* and *Open log* sits above the tabs; when the manager is
offline the tabs give way to an explanation and *Retry now*.

## What each tab does

- **Downloads** — filter chips with live counts: an empty filter dims, a
  non-empty *Failed* turns red, and *History* stands apart on the right. Each
  row shows a status tile (the kind of file, tinted by state; click it for
  details), size, speed and time left, and the one action that fits —
  *Pause*, *Resume*, *Start next*, *Open*, *Retry* or *Again*; ⋮ unfolds the
  rest, labelled (queue moves, open file or folder, copy link, download again,
  remove). Odd states say what is going on: a magnet fetching its file list
  sweeps an indeterminate bar ("Asking peers for the file list · 4
  connected"), a seeding torrent shows upload, ratio and peers with *Stop
  sharing*, a checksum check shows its progress, a download that has not
  received a byte yet says which host it is connecting to, a rule about to fire
  counts down in its badge, and a torrent added held for its file choice gets
  an accent outline, "Waiting for you" and *Choose files*. A failed row gives
  its error in plain words.
  **Select** swaps the toolbar for a selection bar (leave, count, pause,
  resume, remove, select all); Shift-click selects a range and Esc leaves.
  Removing a selection that includes finished downloads asks once, in one
  sentence that names them and their size, with *Remove, keep the files* as
  the primary choice. A finished row whose file is already gone shrinks the
  question to *Remove entry*.
  **History** is grouped by day (Today, Yesterday, This week, Earlier), can be
  searched, and lays its rows out like the live ones (*Open*, *Again* when the
  file is missing, *Retry* for a failure; ⋮ for show in folder, download
  again, copy link, forget). *Clear* asks first and says how many entries it
  forgets. Every empty list says why and what to do next; the first-run one
  offers *Paste from clipboard*, and a search with no match offers to search
  History.
- **Adding** happens in visible steps inside the tab. The form counts the
  links as they are typed ("3 links · 2 direct, 1 magnet"), picks the folder
  as one-tap chips (*Sort by type* when the manager sorts, the presets, the
  chooser), and *Check links* says that nothing starts yet. *Advanced* groups
  every per-download option under foldable headers — File, Connection,
  Request, Check & queue, Torrent & metalink — each saying how many are set,
  and a field keeps its label once it holds a value. Checking shows one line
  per link, each settling as its answer arrives. The review is a card per link
  (size, kind, where it will land, whether it can resume); a link that answered
  with a web page, or failed, is explained and can be opened in the browser or
  skipped, and the primary button counts what will start: **Download 2** or
  **Queue**. If every link failed: *Edit links* or *Add anyway*. A torrent is
  added held and its files shown with a priority chip each (Normal → High →
  Skip on click) and **Start 3 files · 712 MiB**. After it starts:
  "Started 2 · 1 queued".
- **Details** (a row's tile, or the wide window's pane) are short tabs:
  *Overview* (size, done, speed, time left, upload, ratio, seeders,
  connections — or parts and dates for a plain download; the piece map with a
  Have / Downloading / Missing legend; folder, link, info hash and ID with copy
  buttons), *Files* (the tree with per-file progress, green when done, and
  priority chips), *Peers* for a torrent (a table: peer, client, down, up,
  has — fastest first) or *Connections* for HTTP/FTP (grouped by host, a mirror
  thirty times slower than the best marked slow), and *Options* (saved as they
  change, with "2 changes · Undo"). A held torrent opens on its files under
  "Pick files, then start".
- Speeds and sizes (limits, part size, disk cache, a rule's speed threshold) are
  a number plus a unit picker, shown as `12 MiB/s` rather than bytes — the same
  control as the extension's manager page.
- **Actions** — headed by the *Automatic actions* master switch and the
  *Measure speed by* choice (Hybrid, Disk writes, aria2 reported). Each action
  is folded to one line — its name, what it does in words ("Under 50 KiB/s for
  3 s → pause, then resume") and how often it fired today — and one opens at a
  time. Open, it reads as a sentence with editable words: "When an [active]
  [download] stays [below] [50 KiB/s] for [3] s, [pause, then resume] it after
  [1.5] s." The optional conditions (grace period, cooldown, most times,
  progress range, connections, name pattern) are chips with a × and a
  *+ Condition* menu. *Change its options* with nothing to change offers
  *Download limit*, *Connections* or *Other…*. The raw JSON is behind `{ }`,
  says which line does not parse, and keeps *Apply JSON* off until it does.
  Deleting asks inline, saying how often it fired today. With no actions the
  tab offers three templates — kick stalled downloads, restart dead torrents,
  slow down big files — each one click. Edits are held until *Save* in the bar
  that appears at the bottom, or thrown away with *Discard*.
- **Settings** — the same *Simple / Advanced* switch as the manager page.
  Simple is one card with the seven options that decide how a download behaves;
  the counts are steppers (− 16 +). Advanced adds a search that marks the match,
  says "N of M" per group, hides empty groups and opens *Every aria2 option* to
  show its hits; each option shows its aria2 name, a dot when edited and its
  own ↺. Sorting into folders by type is a card per type with its folder and
  its extensions as chips (× to drop one, "+ add"). The aria2c process card
  leads with a health dot, version, pid and uptime; *Restart manager* and
  *Restart aria2c* turn into "Restarting…" until the restart shows up in the
  data, and the panel says "Restarting the manager…" rather than "offline"
  meanwhile. The save bar counts the changes and has *Discard*; a failed save
  keeps the edits, says why and turns *Save* into *Retry*.

The **event log** is no longer a tab of its own. It is diagnostic material
rather than something to watch, so it folds away at the bottom of *Settings*,
under the aria2c process card it usually explains — its header says how many
errors it holds. Unfolded it has filter chips (All, Errors, Actions, aria2c),
tints error lines, copies everything shown in one go, and strips the terminal
colours aria2c writes into its lines. `dms ipc call ariaDownloadManager tab log`
unfolds it and scrolls down to it; click a line to copy it.

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

The detail lines of a load failure ("Type X unavailable", "Cannot assign to
non-existent property") carry no level prefix, so filter on the plugin's name
rather than on `WARN`/`ERROR`. A syntax-only check needs no shell:
`/usr/lib/qt6/bin/qmllint file.qml | grep -A2 "\[syntax\]"` (the import
warnings are noise).

QML traps that fail *silently* here, all hit while building this:

- `property var data` or `property string state` on an `Item` collides with
  built-ins and the whole component fails to load with no message.
- A property you add shadows an id of the same name in the file that uses the
  component: inside `RulesTab { wide: true; service: wide.service }`, `wide`
  is the RulesTab's own bool, not the outer item with `id: wide`.
- Setting a property a DMS widget does not have — `horizontalAlignment` on
  `DankTextField`, say — fails the file, and with it every file that uses it,
  up to the whole widget. Check the installed widget before reaching for a
  property you know from `TextInput`.
- Inline `component` blocks cannot see the ids of the file around them; pass
  state in as properties and send clicks out as signals.
- DMS's `StyledText` defaults to `wrapMode: Text.WordWrap`, so `elide` alone
  does nothing — a long name wraps onto a second line instead. Anything meant
  to stay on one line needs `wrapMode: Text.NoWrap` next to its `elide`.

The look follows the design boards (see `DESIGN-TODO.md`). The controls are
drawn by the plugin from `Theme` tokens rather than taken from DMS, because
the boards' sizes and shapes differ from DMS's widgets: `PillButton` (filled,
tonal, outlined, text and danger kinds), `SearchPill`, `MenuPopup`, `FillField`,
`Segmented`, `Stepper`, `UnitField`, `MiniSlider`, and `OptionField` for a
settings row. Surfaces step up one tone at a time — panel, card
(`surfaceContainer`), field (`surfaceContainerHigh`) — and a field inside a
raised card takes the darker tone instead, through each control's `fill`.

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
├── lib/Rules.js             automatic actions in words: summaries, templates, JSON problems
└── components/
    ├── Aria2Popout.qml      the manager itself — hosted by both the popout and the window
    ├── Aria2Window.qml      standalone window: title bar, window controls, popout or wide layout
    ├── WideManager.qml      the window at 900 px and up: rail, list, detail pane, status bar
    ├── HoverCard.qml        the card shown while hovering the bar icon; PillInput.qml wires hover and middle click
    ├── FilterChips.qml      the Downloads filters; FolderChips.qml the one-tap folder choice
    ├── ManagerActions.qml   header buttons shared by the popout and the window
    ├── BarGlyph.qml         the bar icon: glyph, progress ring, unseen-finished dot
    ├── QuickMenu.qml        the right-click menu, QuickMenuRow.qml one line of it
    └── ...                  one file per tab, plus the row delegates
```

`lib/Actions.js` holds the global actions — endpoints, icons, wording — because
the header row and the quick menu both render them and would otherwise drift.
Only the static half lives there: whether an action is enabled, and the count it
shows, are read off the service in QML, where property capture keeps the
bindings live.
