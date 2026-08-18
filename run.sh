#!/usr/bin/env bash
# Start aria2c-manager. Uses ./.venv if it exists, otherwise the system Python.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

PYTHON=python3
if [[ -x .venv/bin/python ]]; then
  PYTHON=.venv/bin/python
fi

if [[ ! -f config.yaml ]]; then
  echo "config.yaml not found — creating it from config.example.yaml"
  cp config.example.yaml config.yaml
fi

if ! command -v aria2c >/dev/null 2>&1; then
  echo "warning: aria2c is not in PATH. Install it first:" >&2
  echo "  Arch:   sudo pacman -S aria2" >&2
  echo "  Debian: sudo apt install aria2" >&2
fi

exec "$PYTHON" -m aria2c_manager "$@"
