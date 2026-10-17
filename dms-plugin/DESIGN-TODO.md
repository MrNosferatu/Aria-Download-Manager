# DankBar redesign — what is left to build

Hand-off notes for the rest of the redesign. The design canvas is
<https://claude.ai/artifact/N4yTYRi771DJwXH4svvCzW> (20 boards; board numbers below
refer to it). Branch: `dev`. Already done in commit `a483e47` — see "Done" at the
end; verify that first.

## Ground rules

- **Test in the real shell.** `dms ipc call plugins reload ariaDownloadManager`
  reloads the widget, but anything in `services/Aria2Service.qml` (and anything
  already compiled) needs `systemctl --user restart dms`.
- **See QML errors** (they are silent by default):
  `qs log -r "*=true" -t 100000 "$(ls -t /run/user/$UID/quickshell/by-id/*/log.qslog | head -1)" | grep -i aria2`
- **Only use DMS APIs you have checked in the installed DMS**, not upstream
  GitHub — the plugin says `requires_dms >= 1.5.0` and upstream has moved on
  (e.g. `BasePill` is now a thin wrapper around `Modules/SurfaceWidgets/BarPill.qml`).
  Find the install with `find / -path '*quickshell*' -name PluginComponent.qml 2>/dev/null`.
  Safe set (already used by the plugin): `DankIcon`, `StyledText`, `DankButton`,
  `DankActionButton`, `DankTextField`, `DankDropdown`, `DankFilterChips`,
  `DankTabBar`, `DankButtonGroup`, `DankFlickable`, `DankListView`, `DankPopout`,
  `PopoutComponent`, `PluginSettings`/`StringSetting`/`SelectionSetting`/`ToggleSetting`,
  `ToastService`, `Theme.*` (see `grep -rhoE "Theme\.[a-zA-Z]+" dms-plugin | sort -u`).
- **QML traps** (from the README): `property var data` or `property string state`
  on an `Item` silently kills the whole component. Inline `component` blocks
  cannot see ids of the enclosing file — make a separate file (as `BarGlyph.qml`).
  Do not use `font.features` (Qt version dependent; an unknown property fails the
  whole file).
- **Syntax check without a shell**: `pip install PySide6-Essentials` then
  `pyside6-qmllint file.qml | grep "\[syntax\]"` (ignore import warnings).
- Keep the house style: `//:` doc comments that explain *why*, plain-word UI copy,
  one primary button per surface, safe choice as the primary in confirms.

---

## 1. Bar surfaces (boards 3, 11, 12)

### 1.1 Hover card — needs DMS API check
- **Want:** after ~400 ms hover over the pill, a small card: headline
  (`2 downloading` / `3 paused, 1 waiting` / `Nothing downloading` /
  `aria2c stopped` / `Manager not running`), `62% · 3 min`, up to 2 names with %,
  and a hint line `Click · manager   Right-click · actions`. Variants on board 11.
- **How:** put a passive `HoverHandler` inside `horizontalBarPill` /
  `verticalBarPill` in `Aria2Widget.qml` (it does not steal clicks, unlike a
  `MouseArea`). Drive a `Timer` (400 ms) → show. For the surface, check the
  installed DMS for a tooltip that takes multi-line text (`DankTooltip.qml`,
  `DankTooltipV2.qml`, `DTooltip.qml`) — prefer that over a `DankPopout`, which
  grabs focus and has a dismiss layer. Close on hover exit, on click, and when
  the popout or quick menu opens.
- **Data:** all on the service already: `activeTotals` (`progress`, `eta`,
  `left`), `topDownloads`, `pausedCount`, `queuedCount`, `unseenFinished`,
  `aria2.last_error`, `socketPath`.
- **Done when:** hover shows the card in all 5 states; clicking the pill still
  opens the popout; right-click still opens the menu.

### 1.2 Middle-click = pause all / resume all — needs DMS API check
- In upstream `BarPill.qml` the pill's `MouseArea` accepts `Left|Right` only, so
  a middle press falls through to what is under it. Try a
  `TapHandler { acceptedButtons: Qt.MiddleButton }` inside the pill content.
  If it fires in the installed DMS, call the same flip logic as
  `ManagerActions.qml` (`flipAction`). If not, drop it and remove the "Middle ·"
  hint from the hover card.

### 1.3 Hide when idle — needs DMS API check
- Upstream `PluginComponent` has `setVisibilityOverride(bool)` /
  `clearVisibilityOverride()`. If the installed one has them: add
  `ToggleSetting { settingKey: "hideWhenIdle"; defaultValue: false }` to
  `Aria2Settings.qml`, and in `Aria2Widget.qml` call
  `setVisibilityOverride(!(hide && online && !busy && !held && !attention && unseenFinished === 0))`
  whenever those change (guard with `typeof root.setVisibilityOverride === "function"`).
  Never hide while offline or with aria2c down.

### 1.4 Control-center tile progress
- `ccWidgetSecondaryText` already carries `· 62%`. A real progress line needs
  `ccDetailContent` or `controlCenterWidget` — check whether the installed
  version has them; otherwise leave as is. Paused tile: tap should resume
  (`onCcWidgetToggled` → resume-all when `held`).

### 1.5 Quick menu: clipboard preview
- `components/QuickMenu.qml`: when the menu opens, run `wl-paste -n` once
  (a second `Process`) and show the URL host + tail under "Add link from
  clipboard" (two-line row, 48 px; adjust `popupHeight`). Grey the row out if
  the clipboard does not hold a downloadable link.

### 1.6 Plugin settings page (board 12) — `Aria2Settings.qml`
- Group with section headings: **Connection**, **Bar**, **Popout & updates**,
  **Notifications** (plain `StyledText` headings if the installed
  `PluginSettings` has no section widget).
- Connection: show `Connected` / `Not connected` from `Aria2Service.connected`
  next to the socket field, and a *Test* button → `Aria2Service.restart()`.
- Sizes and seconds: use a slider/number setting if the installed DMS has one
  (`find … -name '*Setting.qml'`); otherwise keep `StringSetting`.
- Split *Notify on events* into `notifyFinished` and `notifyErrors`; in
  `Aria2Service._notify` read the new keys, falling back to the old `notify`.
- Optional: a live preview — a `BarGlyph` + label with a state switcher
  (Downloading / Paused / Idle / Error) using fake values.

---

## 2. Popout shell (boards 4, 10)

### 2.1 Compact tabs
- Replace `DankTabBar` in `Aria2Popout.qml` with a 44 px segmented control
  (own `Repeater` of `Rectangle`+`MouseArea`, selected = `Theme.primary` tint).
  Then delete the spacer that works around DankTabBar's underline
  (`Theme.spacingL + Theme.spacingXS`) and fix `chromeHeight` to match exactly.
- Actions tab label already reads `Actions · off` when the master switch is off.

### 2.2 Connecting skeleton
- On first open before the first snapshot (`service.snapshot === null` and not
  yet failed), show 3 skeleton rows in the list area, only after 300 ms
  (Timer), so a fast connect never flashes them.

### 2.3 Success feedback with Undo — `Feedback.qml`, `Aria2Service.notice`
- Change `signal feedback(string message)` to also carry an optional undo
  callback (e.g. keep `root.pendingUndo` on the service). Show `Undo` in the
  pill when present.
- Undoable: *Pause all* (remember the gids that were `active`, undo = resume
  those), single pause/resume. Not undoable: clear finished, remove, clear
  history — no Undo there.
- Optional restyle: inverse colours (light pill on dark), check icon.

### 2.4 Error toasts in plain words
- `Aria2Service.act()` passes raw errors to `ToastService.showError`. Map the
  common ones (unsupported scheme, 403/404, no space, permission denied) to
  "what failed · why · what to do". Finish toasts: check whether the installed
  `ToastService` supports actions; if so add *Open* / *Show in folder*.

---

## 3. Downloads tab (boards 4, 13, 14, 15)

### 3.1 Filter chips — `DownloadsTab.qml`
- `DankFilterChips` cannot style one chip. Replace with an own `Flow` of chips:
  count 0 → dimmed; *Failed* with count > 0 → error tint; *History* pushed to
  the right with a dashed/outlined look. Keep `tab.setFilter(...)` and the
  `emptyState` "Show all downloads" button working (it sets `chips.currentIndex`).

### 3.2 Selection mode (board 14)
- When `tab.selecting`, the bulk bar replaces the search/sort/add row (not
  stacked under it): `✕ · N selected · pause · resume · delete · Select all N`.
- Shift-click on a row's checkbox selects the range from the last clicked;
  `Esc` leaves selection mode.
- Bulk remove confirm as one sentence naming the finished file(s) and size:
  "2 unfinished will be cancelled and their part files deleted. 1 is finished —
  wallpaper-pack-v3.zip (1.2 GB)." Buttons: **Remove, keep the file** (primary),
  *Remove and delete file* (error), *Cancel*.
- Row with `fileMissing`: confirm strip collapses to one button *Remove entry*.

### 3.3 History (board 15) — `DownloadsTab.qml`, `HistoryRow.qml`
- Day groups: `ListView.section` on a computed `day` field (Today / Yesterday /
  This week / Earlier) from `finished_at`.
- Search works in history (filter `historyEntries` by name); remove the
  "Search is not available in history" placeholder.
- History rows: same layout as `DownloadRow` (status tile, one action:
  *Open*, or *Again* when the file is missing, or *Retry* for a failure, plus ⋮
  with *Show in folder*, *Download again*, *Forget*).
- Clear-history confirm is done; say how many entries it forgets
  (`service.history.summary.count`).

### 3.4 Rows in special states — `DownloadRow.qml`
- **Fetching details** (`dl.isMetadata`): indeterminate bar, meta
  "Asking peers for the file list · N connected".
- **Seeding** (`dl.seeder`): green tile, meta "↑ speed · ratio · peers",
  primary action *Stop sharing* (find the endpoint the DetailPanel's
  "Stop sharing when done" uses).
- **Rule about to fire**: badge "Stall kick in 0.9 s" from
  `ruleInfo[name].elapsed/threshold` instead of "<name> acting".
- **Verifying checksum**: check which field aria2 reports
  (`verifiedLength` / `verifyIntegrityPending` in `tellStatus`); if the manager
  passes it through, show "Verifying checksum · 64%".
- **Held torrent** (added held, waiting for a file choice): accent outline and
  meta "Waiting for you — pick files", primary action *Choose files*
  (expands the detail).

---

## 4. Add flow (boards 5, 16) — `AddPanel.qml`

Stages already exist: `form` → `busy` → `file` / `torrent`. Rework inside them:

- **form:** under the links box, a live count: "3 links · 2 direct, 1 magnet".
  Folder as one-tap preset chips (*Sort by type*, the presets, the chooser) instead
  of a field. Rename *Next* → **Check links**.
- **Advanced:** group the fields under four foldable headers — *File* (save to,
  save as), *Connection* (connections, parts, smallest part, speed limit),
  *Request* (referer, user agent, cookies, proxy, extra headers), *Check & queue*
  (checksum, queue position), *Torrent & metalink* (file path, download only).
  Each header shows "· N set". Keep labels visible once a field has a value.
- **busy:** one row per link with its own spinner → check mark / error as
  results arrive (if the probe is one request for all links, show all spinners
  and resolve together).
- **file (review):** one card per link (tile, name, size · type · → folder,
  "Resumable"). A link that answered with a web page gets an error card with
  *Open in browser* (`xdg-open url`) and *Skip this link*; the batch continues.
  Primary button counts what will start: **Download 2**; *Download later* →
  **Queue**. All links failed → "None of these can be downloaded", *Edit links*,
  *Add anyway*.
- **torrent:** priority as a small chip per file (High / Normal / Skip) instead
  of a dropdown; running total "3 of 5 files · 712 MB"; primary **Start 3 files**.
- After submit: feedback "Started 2 · 1 queued".

---

## 5. Download detail (boards 6, 17) — `DetailPanel.qml`

Currently one long scroll: problems (line ~279), files tree (~299), options
(~609), review button (~858), technical record (~869: pieces, paths,
connections, peers).

- Add a tab row at the top: **Overview · Files · Peers/Connections · Options**
  (show *Peers* for torrents, *Connections* for HTTP/FTP; *Files* only when
  there is more than one file). One section visible at a time.
- **Overview:** stat grid 4×2 (Size, Downloaded, Speed, Time left, Uploaded,
  Ratio, Seeders "14 of 40", Connections), piece map with a legend
  (Have / Downloading / Missing, distinct in lightness), paths with copy buttons.
- **Files:** existing tree; add a per-file mini progress bar and green when done.
- **Peers:** a table with header (Peer, Client, ↓, ↑, Has), sorted by ↓.
- **Connections (HTTP):** group by host: dot (green/amber), host, speed,
  connection count; a mirror 30× slower than the best gets "Slow" and a
  *Drop this mirror* button (if the API can remove a URI; otherwise omit).
- **Options:** keep "saved as they change"; add a small "1 change · Undo" line.
- **Held torrent:** heading "Pick files, then start", text that nothing is
  transferred yet, primary **Start 2 files · 2.8 GB**.

---

## 6. Actions tab (boards 7, 18) — `RulesTab.qml`, `RuleCard.qml`

Done: master switch card, plain speed-source labels, save bar.

- **Collapsed by default:** each rule a one-line summary
  ("Under 50 KiB/s for 3 s → pause, then resume") + "fired N× today" (count from
  `service.triggers` by rule name and today's date). One card open at a time.
- **Sentence editor** in the open card: "When an [active ▾] [normal download ▾]
  stays below [50 KiB/s] for [3 s], [pause, then resume ▾] it after [1.5 s]."
  Tokens are inline editors bound to `when.statuses`, `torrent_only/http_only`,
  `when.speed_below`, `when.for_seconds`, `action`, `resume_after_seconds`.
- **Optional conditions** as removable chips + "+ Condition" menu: ignore the
  first N s (`when.min_age_seconds`), cooldown, max times, only past / before %,
  connections below, name matches.
- **Raw JSON** behind a `{ }` icon per card; on parse error show
  "Line 5: …" and disable *Apply JSON*.
- **Delete:** inline confirm "Delete “Stall kick”? It fired 12 times today."
- **"Change its options" with no options:** amber card with quick-add buttons
  (*Download limit* → `max-download-limit`, *Connections* →
  `max-connection-per-server`, *Other…* → JSON).
- **Empty state** with three templates (one click adds and opens the card):
  - Kick stalled downloads — `speed_below 51200, for_seconds 3, action pause_resume`
  - Restart dead torrents — `torrent_only, speed_below 1024, for_seconds 120, min_progress 5, action restart`
  - Slow down big files — `name_matches "\\.iso$", action set_option, options {"max-download-limit": "2M"}`

---

## 7. Settings tab (boards 8, 19) — `SettingsTab.qml`

Done: save bar that appears only when an edit differs from what is saved.

- **Discard** on the save bar: clear `edits`, `optionsDirty = false`,
  `seedRouting()`, and reset every field — fields keep their own `value`, so
  either bump a `property int generation` that the field `Repeater`s use as part
  of their model (forces re-creation) or add a `resetRequested` signal the
  fields listen to (`value = original`).
- **Simple mode:** steppers (− value +) for downloads at once, connections per
  server, parts; one grey help line per setting.
- **Advanced search:** highlight the match, show "N of M" per group, hide empty
  groups, show the aria2 key under each label, per-option reset (↺) when edited.
- **Sort by type** (~line 400): one card per category with extension chips
  (× to remove, "+ add" to add) and the folder; keep the data shape
  (`routingExtensions[category]` is an array).
- **aria2c process card:** health dot, version, pid, uptime (if
  `service.aria2` has them).
- **Event log** (`LogTab.qml`): filter chips (All / Errors / Actions / aria2c,
  by `level` and kind), tint error lines, *Copy all*, and the folded header says
  "2 errors" when there are any.
- **Restarting manager / aria2c:** inline status "Restarting…" with a spinner
  until the next snapshot arrives; save failure: an error bar with the reason
  and *Retry*, keeping the edits.

---

## 8. Standalone window (boards 9, 20) — `Aria2Window.qml`

Today the window hosts `Aria2Popout` with `inWindow: true`.

- At ≥ 900 px wide, a three-pane layout:
  - **Rail** (≈210 px): *Add download* button, then All / Active / Queued /
    Paused / Done / Failed / History with counts, then Actions (`3 on` / `off`)
    and Settings.
  - **List:** `DownloadsTab` without its chips (filter driven by the rail),
    selecting a row instead of expanding it.
  - **Detail pane** (≈340 px): `DetailPanel` for the selected gid, with
    *Pause*, *Folder*, *Cancel* buttons on top.
  - **Status bar:** ↓ speed, ↑ speed, left · time, aria2c status dot + version,
    "Automatic actions on/off".
- Actions section: rule list on the left, the open rule's editor and its own
  trigger history on the right. Settings: groups on the left, options right.
- Offline: rail stays (disabled), centre shows the same offline message as the
  popout.
- Under 900 px: fall back to the current popout layout.
- Needs `DownloadsTab` to take `filter` from outside, a `selectedGid` output, and
  a mode where clicking selects instead of expanding.

---

## Done in `a483e47` — verify these first

- [ ] Bar: ring appears while downloading and tracks progress; hidden for a
      magnet still fetching metadata; *Progress ring* setting turns it off.
- [ ] Bar: speed label does not change width tick to tick; paused-only shows
      muted `pause_circle` + "N paused"; aria2c down shows "aria2c down";
      offline is a dimmed icon with no text; finishing a download with the
      panel closed shows a dot that clears when the panel opens.
- [ ] Bar: count mode "2 +3"; vertical bar shows speed on two lines and
      nothing when idle.
- [ ] Quick menu: height matches content in every state (idle, downloading,
      paused, aria2c down, offline) — `popupHeight` is computed by hand.
- [ ] Quick menu: per-download pause/resume; bulk buttons grey out correctly;
      *Automatic actions* switch flips and the menu stays open; *Open manager*
      opens the popout.
- [ ] Popout: stat strip sparkline draws after a few seconds; banner appears
      when aria2c is stopped and *Open log* lands on the log; offline screen
      hides the tabs, *Copy* copies the socket path.
- [ ] Popout header: one pause/resume button flips; *Clear finished* greys
      out with nothing finished.
- [ ] Rows: status tile icon by file type, click opens details; one primary
      action; ⋮ shows the labelled strip; remove confirm still works.
- [ ] Empty states for each filter / search / history; *Clear history* asks.
- [ ] Actions tab: master card toggles; save bar appears after an edit,
      *Discard* reverts, *Save* saves.
- [ ] Settings tab: save bar stays hidden on open (fields seeding must not
      trip it), appears after a real edit, hides after *Save*.
