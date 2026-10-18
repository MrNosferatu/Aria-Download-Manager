#!/usr/bin/env bash
# Install Aria Download Manager for this user, from this checkout:
#   - aria2 (and, if wanted, qbittorrent-nox and ffmpeg) from the distro
#   - the Python dependencies, in ./.venv if the system Python lacks them
#   - a systemd user service that starts the manager at login
#   - the browser extension's native-messaging bridge
#   - the DankMaterialShell plugin, when DMS is installed
# Safe to run again (after a git pull, or a move of the checkout).
#
#   ./install.sh               install, asking before anything that needs sudo
#   ./install.sh -y            install, answering yes
#   ./install.sh --dry-run     print what would be done, change nothing
#   ./install.sh --uninstall   remove the service, bridge and plugin link
#                              (downloads, history and settings are kept)
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
ROOT=$PWD
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/aria-download-manager.service"
DMS_PLUGIN="$HOME/.config/DankMaterialShell/plugins/ariaDownloadManager"
HOST=aria_download_manager
RELEASES=https://github.com/MrNosferatu/Aria-Download-Manager/releases

YES=0
DRY=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    -y | --yes) YES=1 ;;
    --dry-run) DRY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h | --help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
run() {
  if ((DRY)); then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
}
ask() {
  ((YES)) && return 0
  local reply
  read -r -p "    $1 [Y/n] " reply
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- uninstall
if ((UNINSTALL)); then
  say "Stopping and removing the service"
  if [[ -f "$UNIT" ]]; then
    run systemctl --user disable --now aria-download-manager.service || true
    run rm -f "$UNIT"
    run systemctl --user daemon-reload
  fi
  say "Removing the browser bridge"
  for f in "$HOME/.mozilla/native-messaging-hosts/$HOST.json" \
           "$HOME/.librewolf/native-messaging-hosts/$HOST.json" \
           "$HOME"/.config/*/NativeMessagingHosts/"$HOST".json \
           "$HOME"/.config/*/*/NativeMessagingHosts/"$HOST".json; do
    [[ -f "$f" ]] && run rm -f "$f"
  done
  run rm -f "$HOME/.local/share/aria-download-manager/native-host"
  if [[ -L "$DMS_PLUGIN" && "$(readlink -f "$DMS_PLUGIN")" == "$ROOT/dms-plugin" ]]; then
    say "Removing the DankBar plugin link"
    run rm -f "$DMS_PLUGIN"
  fi
  say "Done. Kept: your downloads, config.yaml and ~/.local/share/aria-download-manager (history)."
  exit 0
fi

# ---------------------------------------------------------------- packages
pm=""
if have pacman; then pm=pacman
elif have apt-get; then pm=apt
elif have dnf; then pm=dnf
fi

install_pkgs() {
  case "$pm" in
    pacman) run sudo pacman -S --needed --noconfirm "$@" ;;
    apt) run sudo apt-get install -y "$@" ;;
    dnf) run sudo dnf install -y "$@" ;;
  esac
}

say "Checking packages"
have python3 || { echo "python3 is required" >&2; exit 1; }

if have aria2c; then
  note "aria2c         found"
elif [[ -n "$pm" ]] && ask "aria2 is required. Install it with $pm?"; then
  install_pkgs aria2
else
  echo "aria2 is required: install it with your package manager, then run this again." >&2
  exit 1
fi

optional=()
have qbittorrent-nox && note "qbittorrent-nox found" || optional+=(qbittorrent-nox)
have ffmpeg && note "ffmpeg         found" || optional+=(ffmpeg)
# The download-only VPN's WireGuard client; packaged on Arch.
if have wireproxy; then
  note "wireproxy      found"
elif [[ "$pm" == pacman ]]; then
  optional+=(wireproxy)
fi
if ((${#optional[@]})); then
  note "Optional: qbittorrent-nox gives torrents real per-file priorities;"
  note "ffmpeg saves streamed video (HLS/DASH) from the page's Download button;"
  note "wireproxy runs the VPN for downloads only (Settings → VPN)."
  if [[ -n "$pm" ]] && ask "Install ${optional[*]} too?"; then
    install_pkgs "${optional[@]}"
  fi
fi

# ---------------------------------------------------------------- python
say "Checking Python dependencies"
if python3 -c 'import fastapi, aiohttp, yaml' 2>/dev/null; then
  PY=$(command -v python3)
  note "system Python has them"
else
  if ! python3 -c 'import venv, ensurepip' 2>/dev/null; then
    if [[ "$pm" == apt ]] && ask "python3-venv is needed for a virtual environment. Install it?"; then
      install_pkgs python3-venv
    else
      echo "Python's venv module is missing; install it (Debian/Ubuntu: python3-venv)." >&2
      exit 1
    fi
  fi
  note "installing them into $ROOT/.venv"
  [[ -x .venv/bin/python ]] || run python3 -m venv .venv
  run .venv/bin/pip install --quiet -r requirements.txt
  PY="$ROOT/.venv/bin/python"
fi

if [[ ! -f config.yaml ]]; then
  say "Creating config.yaml from config.example.yaml"
  run cp config.example.yaml config.yaml
fi

# ---------------------------------------------------------------- service
say "Installing the systemd user service"
unit_text=$(sed -e "s|^Documentation=.*|Documentation=file:$ROOT/README.md|" \
                -e "s|^WorkingDirectory=.*|WorkingDirectory=$ROOT|" \
                -e "s|^ExecStart=.*|ExecStart=$PY -m aria_download_manager|" \
                systemd/aria-download-manager.service)
if ((DRY)); then
  note "[dry-run] write $UNIT:"
  printf '%s\n' "$unit_text" | sed 's/^/      /'
else
  mkdir -p "$UNIT_DIR"
  printf '%s\n' "$unit_text" > "$UNIT"
fi
run systemctl --user daemon-reload
run systemctl --user enable aria-download-manager.service
# restart rather than start, so a re-run picks up a pull or a moved checkout
run systemctl --user restart aria-download-manager.service

# ---------------------------------------------------------------- browser bridge
say "Registering the browser extension's bridge"
run "$PY" -m aria_download_manager --install-native-host

# ---------------------------------------------------------------- DankBar
if have dms && [[ -d "$HOME/.config/DankMaterialShell" ]]; then
  say "Installing the DankBar plugin"
  if [[ "$(readlink -f "$DMS_PLUGIN" 2>/dev/null)" == "$ROOT/dms-plugin" ]]; then
    note "already linked"
  elif [[ -e "$DMS_PLUGIN" ]]; then
    note "$DMS_PLUGIN exists and is not this checkout's; left alone"
  else
    run mkdir -p "$(dirname "$DMS_PLUGIN")"
    run ln -s "$ROOT/dms-plugin" "$DMS_PLUGIN"
  fi
  if ((DRY)); then
    note "[dry-run] dms ipc call plugins enable ariaDownloadManager"
  else
    dms ipc call plugins enable ariaDownloadManager >/dev/null 2>&1 || true
  fi
  note "Add it to the bar in DMS Settings → DankBar."
fi

# ---------------------------------------------------------------- done
say "Done. The manager runs now and at every login."
note "Last step, the browser extension:"
note "  Firefox:  open the .xpi from $RELEASES"
note "  Chromium: chrome://extensions → Developer mode → Load unpacked →"
note "            $ROOT/extension, then run ./install.sh again (it registers"
note "            the bridge for the extension it finds there)."
note "  Restart the browser once afterwards."
note "Status: systemctl --user status aria-download-manager"
