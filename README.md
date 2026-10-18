# Aria Download Manager

A download manager for Linux built on **aria2c** (and **qBittorrent** for
torrents), driven from a browser extension and, optionally, a
[DankMaterialShell](https://danklinux.com) bar widget.

- Takes over the browser's downloads, cookies and all, so login-protected
  files and JavaScript-triggered downloads just land in the queue.
- Queueing, parallel downloads, split files, connections per server, speed
  limits, history that survives restarts.
- Torrents with real per-file priorities and file choice before downloading,
  through a qBittorrent the manager runs itself.
- A **Download** button over a page's video player (HLS/DASH through ffmpeg).
- Automatic actions on misbehaving downloads, e.g. *under 50 KiB/s for 3
  seconds → pause and resume*.

```
Extension ──native messaging──→ bridge ──┐
                                         ├─ Unix socket ─→ manager ─→ aria2c / qBittorrent
DankBar widget (optional) ───────────────┘
```

The manager opens no network port: it listens only on a user-only Unix socket
(`$XDG_RUNTIME_DIR/aria-download-manager.sock`), so no website can reach it and
an in-browser VPN cannot get in the way.

## Install

```bash
git clone https://github.com/MrNosferatu/Aria-Download-Manager.git
cd Aria-Download-Manager
./install.sh
```

The installer, safe to run again after a `git pull`:

1. installs **aria2** with pacman, apt or dnf (asking first), and offers
   **qbittorrent-nox** (torrent priorities) and **ffmpeg** (streamed video);
2. installs the Python dependencies into `.venv` if the system Python lacks them;
3. starts the manager as a systemd user service, now and at every login;
4. registers the extension's native-messaging bridge;
5. links and enables the DankBar plugin if DankMaterialShell is installed.

`./install.sh --dry-run` shows what it would do; `-y` skips the questions.

### The browser extension

- **Firefox:** open the `.xpi` from
  [Releases](https://github.com/MrNosferatu/Aria-Download-Manager/releases).
- **Chromium:** `chrome://extensions` → *Developer mode* → *Load unpacked* →
  this checkout's `extension/` folder, then run `./install.sh` again so the
  bridge registers that extension.

Restart the browser once. Flatpak and Snap browsers cannot start the bridge;
use a native package.

### The DankBar widget

After the installer, add it in DMS *Settings → DankBar*. Left-click opens the
panel, right-click gives quick actions, and the panel can be detached into a
window. Useful key bindings:

```sh
dms ipc call ariaDownloadManager toggle        # the bar panel
dms ipc call ariaDownloadManager toggleWindow  # the standalone window
```

More in [dms-plugin/README.md](dms-plugin/README.md).

## Using it

- **Toolbar popup:** live speed, what is running, a box for a link or magnet,
  the *Send downloads to Aria* switch, and *open the full manager*.
- **Right-click** a link, image, video, page or selection to send it; Alt+click
  sends any link.
- **Manager page / DankBar panel:** downloads with details (files, peers,
  piece map, options), Add, the automatic Actions, and Settings (*Simple* or
  every aria2 option under *Advanced*).
- Removing an unfinished download deletes its partial file; a finished one asks
  whether to keep the file.

## Configuration

Everything is editable in the UI; it is stored in `config.yaml` (created from
`config.example.yaml`). A few keys worth knowing:

| Key | Default | Meaning |
| --- | --- | --- |
| `torrent.engine` | `auto` | `auto` uses qbittorrent-nox when installed, `aria2` keeps torrents on aria2c |
| `qbittorrent.managed` | `true` | `false` to use a qBittorrent you already run |
| `aria2.stop_on_exit` | `true` | `false` keeps aria2c downloading after the manager stops |
| `desktop.float_windows` | `true` | float the download dialog and window on niri / Hyprland |
| `rules` | stall recovery | the automatic actions (also on the *Actions* tab) |

`python3 -m aria_download_manager --print-config` shows the effective config.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Extension: "the native host is not installed" | run `./install.sh` (or `python3 -m aria_download_manager --install-native-host`), restart the browser |
| "Aria Download Manager is not running" | `systemctl --user status aria-download-manager`; logs with `journalctl --user -u aria-download-manager` |
| `aria2c exited during startup` | usually a bad option in `aria2.options`; see `~/.local/share/aria-download-manager/aria2.log` |
| A download still lands in the browser | capture is off, the site is excluded in Settings, or it is a `blob:`/`data:` URL aria2 cannot fetch |
| Torrents go to aria2c | qbittorrent-nox is missing or could not start; Settings says why |

## Uninstall

```bash
./install.sh --uninstall
```

Removes the service, the bridge and the plugin link; your downloads, settings
and history stay.

## Development

```bash
./run.sh                           # run in the foreground instead of the service
python3 tests/test_manager.py      # the manager, against a fake aria2 (no aria2c needed)
python3 tests/test_ipc.py          # socket, live stream, native-messaging bridge
python3 tests/test_qbittorrent.py  # torrents through a real qbittorrent-nox (skipped if absent)
python3 tests/test_compositor.py   # window handling on niri / Hyprland (faked)
python3 tests/test_filetree.py     # the torrent file tree, shared by both front-ends
```

The extension is released automatically: a push to `main` with a new version in
`extension/manifest.json` builds, signs and publishes it
(`.github/workflows/extension-release.yml`).

```
aria_download_manager/  the manager: API, socket, aria2 and qBittorrent, rules, history
extension/              browser extension (Firefox + Chromium, MV3) and the manager page
dms-plugin/             DankMaterialShell widget
systemd/                user service template (install.sh fills in the paths)
tests/                  suites, fake aria2, UI render harness
```
