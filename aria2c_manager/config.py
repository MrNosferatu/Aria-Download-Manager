"""Configuration loading / merging / persistence."""

from __future__ import annotations

import copy
import os
import secrets
import threading
from pathlib import Path
from typing import Any

import yaml

PKG_DIR = Path(__file__).resolve().parent
PROJECT_DIR = PKG_DIR.parent
STATIC_DIR = PKG_DIR / "static"

DEFAULT_STATE_DIR = Path(
    os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")
) / "aria2c-manager"

# Every key under aria2.options must be a real aria2c long option name; they are
# passed straight to the process as --key=value and aria2c aborts on unknown ones.
DEFAULTS: dict[str, Any] = {
    "server": {
        "host": "127.0.0.1",
        "port": 6810,
        # No auth by design: the socket is bound to loopback only.
        "open_browser": False,
        # Serve the browser UI at /. Off by default: the DankMaterialShell
        # widget and the browser extension both drive the API directly, so the
        # UI is opt-in. The REST/SSE API is served either way.
        "web_ui": False,
    },
    "poll_interval": 1.0,
    # Used when nothing is downloading and no UI is connected to the stream.
    "poll_interval_idle": 5.0,
    "aria2": {
        "managed": True,
        "binary": "aria2c",
        "restart_on_exit": True,
        # false = leave aria2c running when the manager exits (downloads carry on;
        # the next run adopts it). true = shut it down with the manager.
        "stop_on_exit": True,
        "startup_timeout": 20.0,
        "rpc": {
            "host": "127.0.0.1",
            "port": 6800,
            # Empty + managed => a random per-run secret is generated.
            "secret": "",
        },
        "session_file": str(DEFAULT_STATE_DIR / "aria2.session"),
        "log_file": str(DEFAULT_STATE_DIR / "aria2.log"),
        "extra_args": [],
        "options": {
            "dir": str(Path.home() / "Downloads"),
            "continue": "true",
            "max-concurrent-downloads": "5",
            "max-connection-per-server": "16",
            "split": "16",
            "min-split-size": "1M",
            "max-tries": "10",
            "retry-wait": "5",
            "timeout": "60",
            "connect-timeout": "30",
            "max-overall-download-limit": "0",
            "max-download-limit": "0",
            "max-overall-upload-limit": "0",
            "max-upload-limit": "0",
            "file-allocation": "prealloc",
            "auto-file-renaming": "true",
            "allow-overwrite": "false",
            "disk-cache": "32M",
            "follow-torrent": "true",
            "bt-max-peers": "55",
            "seed-ratio": "1.0",
            "enable-dht": "true",
            "http-accept-gzip": "true",
            "remote-time": "true",
            "console-log-level": "warn",
            "log-level": "notice",
            "summary-interval": "0",
        },
    },
    # Finished-download history. aria2's session file only keeps *unfinished*
    # downloads, so completed ones would vanish on restart without this.
    "history": {
        "enabled": True,
        "file": str(DEFAULT_STATE_DIR / "history.json"),
        "max_entries": 2000,
    },
    "rules_enabled": True,
    # Which speed figure rules judge by. Per-rule override: when.speed_source.
    #   aria2    - aria2's own downloadSpeed (a moving average; lags a stall)
    #   measured - bytes actually written over the last few seconds (immediate,
    #              but unknown for the first couple of ticks, and a rule will not
    #              fire on an unknown speed)
    #   hybrid   - measured when available, else aria2's figure (default)
    "rules_speed_source": "hybrid",
    "rules": [
        {
            "name": "stall-recovery",
            "enabled": True,
            "description": "Pause+resume a download that drops below 50 KiB/s for 3s.",
            "when": {
                "statuses": ["active"],
                "speed_below": 51200,
                "for_seconds": 3,
                "min_age_seconds": 8,
                "max_progress": 99.0,
            },
            "action": "pause_resume",
            "resume_after_seconds": 1.5,
            "cooldown_seconds": 25,
            "max_triggers": 20,
        },
        {
            "name": "dead-download-restart",
            "enabled": False,
            "description": "Fully re-add a download stuck at 0 B/s for 60s.",
            "when": {
                "statuses": ["active"],
                "speed_below": 1,
                "for_seconds": 60,
                "min_age_seconds": 15,
            },
            "action": "restart",
            "cooldown_seconds": 120,
            "max_triggers": 5,
        },
    ],
}


def deep_merge(base: dict, over: dict) -> dict:
    """Recursively merge ``over`` into a copy of ``base``."""
    out = copy.deepcopy(base)
    for key, value in (over or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = copy.deepcopy(value)
    return out


def expand(path_like: str | os.PathLike) -> Path:
    return Path(os.path.expandvars(str(path_like))).expanduser()


class Config:
    """Mutable config backed by a YAML file.

    Only the keys that differ from :data:`DEFAULTS` are written back, so the
    file stays readable and future default changes still reach the user.
    """

    def __init__(self, path: str | os.PathLike | None = None):
        self.path = Path(path).expanduser() if path else PROJECT_DIR / "config.yaml"
        self._lock = threading.Lock()
        self._user: dict[str, Any] = {}
        self.data: dict[str, Any] = copy.deepcopy(DEFAULTS)
        self.runtime_secret: str = ""
        self.load()

    # ---- io -------------------------------------------------------------
    def load(self) -> None:
        user: dict[str, Any] = {}
        if self.path.is_file():
            loaded = yaml.safe_load(self.path.read_text(encoding="utf-8"))
            if loaded and not isinstance(loaded, dict):
                raise ValueError(f"{self.path}: top level must be a mapping")
            user = loaded or {}
        self._user = user
        self.data = deep_merge(DEFAULTS, user)
        self._post_load()

    def _post_load(self) -> None:
        aria2 = self.data["aria2"]
        secret = str(aria2["rpc"].get("secret") or "")
        if not secret and aria2.get("managed", True):
            # Kept in the state dir rather than in memory so that a *new* run can
            # still talk to an aria2c left behind by an old one (terminal closed,
            # crash) and adopt it instead of failing to bind the RPC port.
            secret = self._stored_secret()
        aria2["rpc"]["secret"] = secret
        for key in ("session_file", "log_file"):
            aria2[key] = str(expand(aria2[key]))
        history = self.data.setdefault("history", {})
        if history.get("file"):
            history["file"] = str(expand(history["file"]))
        options = aria2["options"]
        if options.get("dir"):
            options["dir"] = str(expand(options["dir"]))
        # aria2 RPC and aria2c CLI both want plain strings.
        aria2["options"] = {k: stringify(v) for k, v in options.items() if v is not None}

    def _stored_secret(self) -> str:
        """Read (or create) the auto-generated RPC secret, mode 0600."""
        if self.runtime_secret:
            return self.runtime_secret
        path = DEFAULT_STATE_DIR / "rpc-secret"
        try:
            if path.is_file():
                existing = path.read_text(encoding="utf-8").strip()
                if existing:
                    self.runtime_secret = existing
                    return existing
        except OSError:
            pass
        self.runtime_secret = secrets.token_urlsafe(24)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(self.runtime_secret, encoding="utf-8")
            path.chmod(0o600)
        except OSError:
            pass  # in-memory only; adoption just will not work
        return self.runtime_secret

    def save(self) -> None:
        """Persist the user-visible subset of the current config."""
        with self._lock:
            payload = copy.deepcopy(self._user)
            payload["rules"] = copy.deepcopy(self.data.get("rules", []))
            payload["rules_enabled"] = bool(self.data.get("rules_enabled", True))
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(self.path.suffix + ".tmp")
            tmp.write_text(
                yaml.safe_dump(payload, sort_keys=False, allow_unicode=True),
                encoding="utf-8",
            )
            tmp.replace(self.path)
            self._user = payload

    # ---- access ---------------------------------------------------------
    def get(self, dotted: str, default: Any = None) -> Any:
        node: Any = self.data
        for part in dotted.split("."):
            if not isinstance(node, dict) or part not in node:
                return default
            node = node[part]
        return node

    @property
    def rules(self) -> list[dict]:
        return list(self.data.get("rules", []))

    @rules.setter
    def rules(self, value: list[dict]) -> None:
        self.data["rules"] = list(value)

    def public(self) -> dict:
        """Config for the UI. Drops the RPC secret."""
        data = copy.deepcopy(self.data)
        data["aria2"]["rpc"]["secret"] = "***" if data["aria2"]["rpc"]["secret"] else ""
        data["config_path"] = str(self.path)
        return data


def stringify(value: Any) -> Any:
    """aria2 wants strings (or lists of strings, e.g. for ``header``)."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (list, tuple)):
        return [stringify(v) for v in value]
    return str(value)
