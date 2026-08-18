"""Custom download-action rules.

A rule watches every download each poll tick. When its ``when`` conditions hold
continuously for ``for_seconds``, its action fires once, then the rule goes into
``cooldown_seconds`` for that download.

Example (the requirement-4 behaviour): pause+resume any download whose speed
stays under 50 KiB/s for 3 seconds.

    - name: stall-recovery
      enabled: true
      when:
        statuses: [active]
        speed_below: 51200      # bytes/s
        for_seconds: 3
        min_age_seconds: 8      # ignore ramp-up right after start
        max_progress: 99.0      # don't poke a download that's basically done
      action: pause_resume
      resume_after_seconds: 1.5
      cooldown_seconds: 25
      max_triggers: 20
"""

from __future__ import annotations

import asyncio
import re
import time
from dataclasses import dataclass, field
from typing import Any

from .config import Config, stringify
from .rpc import Aria2Error, Aria2RPC
from .state import Store

ACTIONS = (
    "pause_resume",
    "force_pause_resume",
    "restart",
    "set_option",
    "stop",
    "log_only",
)

#: How each action reads in the event log. The keys stay as-is: they are the
#: literal values used in config.yaml.
#: Accepted values for rules_speed_source / when.speed_source.
SPEED_SOURCES = ("aria2", "measured", "hybrid")

ACTION_PHRASES = {
    "pause_resume": "paused and resumed",
    "force_pause_resume": "force-paused and resumed",
    "restart": "restarted",
    "set_option": "changed options on",
    "stop": "paused",
    "log_only": "noted",
}


@dataclass
class TrackState:
    elapsed: float = 0.0
    triggers: int = 0
    last_trigger: float = 0.0
    acting: bool = False


@dataclass
class Tracker:
    first_seen: float = field(default_factory=time.time)
    #: When this download last *started transferring*. `min_age_seconds` is
    #: measured from here, not from first_seen: a download can sit queued for
    #: minutes and must still get its grace period once it finally starts.
    active_since: float = 0.0
    rules: dict[str, TrackState] = field(default_factory=dict)

    def state(self, rule_name: str) -> TrackState:
        return self.rules.setdefault(rule_name, TrackState())


class RuleEngine:
    def __init__(self, cfg: Config, rpc: Aria2RPC, store: Store):
        self.cfg = cfg
        self.rpc = rpc
        self.store = store
        self.tracked: dict[str, Tracker] = {}
        self.trigger_log: list[dict] = []

    # ---- config ----------------------------------------------------------
    @property
    def enabled(self) -> bool:
        return bool(self.cfg.get("rules_enabled", True))

    def active_rules(self) -> list[dict]:
        return [r for r in self.cfg.rules if r.get("enabled", True) and r.get("name")]

    def validate(self, rule: dict) -> list[str]:
        problems: list[str] = []
        if not str(rule.get("name", "")).strip():
            problems.append("rule needs a name")
        action = rule.get("action", "log_only")
        if action not in ACTIONS:
            problems.append(f"unknown action {action!r} (expected one of {', '.join(ACTIONS)})")
        when = rule.get("when") or {}
        if not isinstance(when, dict):
            problems.append("'when' must be a mapping")
            return problems
        if not any(
            k in when
            for k in ("speed_below", "speed_above", "connections_below", "progress_stuck")
        ):
            problems.append("'when' needs at least one of: speed_below, speed_above, connections_below")
        if float(when.get("for_seconds", 0) or 0) < 0:
            problems.append("for_seconds must be >= 0")
        if action == "set_option" and not isinstance(rule.get("options"), dict):
            problems.append("action set_option requires an 'options' mapping")
        if name_re := when.get("name_matches"):
            try:
                re.compile(str(name_re))
            except re.error as exc:
                problems.append(f"name_matches is not a valid regex: {exc}")
        return problems

    # ---- evaluation ------------------------------------------------------
    def speed_source(self, when: dict | None = None) -> str:
        source = str(
            (when or {}).get("speed_source")
            or self.cfg.get("rules_speed_source")
            or "hybrid"
        ).strip().lower()
        return source if source in SPEED_SOURCES else "hybrid"

    def speed_of(self, dl: dict, when: dict | None = None) -> int | None:
        """The speed figure a rule should judge by, or None when unknown.

        aria2   — aria2's own downloadSpeed. A moving average, so it keeps
                  reporting a healthy figure for seconds after a stall.
        measured— bytes actually written over the last few seconds. Reacts at
                  once; None until enough samples exist, and a rule will not fire
                  on an unknown speed.
        hybrid  — measured when available, otherwise aria2's figure (default).
        """
        source = self.speed_source(when)
        aria2_speed = int(dl.get("downloadSpeed") or 0)
        measured = dl.get("measuredSpeed")
        if source == "aria2":
            return aria2_speed
        if source == "measured":
            return None if measured is None else int(measured)
        return aria2_speed if measured is None else int(measured)

    def _matches(self, when: dict, dl: dict, tracker: Tracker, now: float) -> bool:
        statuses = when.get("statuses") or ["active"]
        if dl["status"] not in statuses:
            return False
        # Grace period counts from the moment it started running, so a download
        # promoted out of a long queue is not judged on its first instant.
        reference = tracker.active_since or tracker.first_seen
        if now - reference < float(when.get("min_age_seconds", 0) or 0):
            return False
        speed = self.speed_of(dl, when)
        if "speed_below" in when or "speed_above" in when:
            if speed is None:
                return False  # no reliable measurement yet: do not act on a guess
            if "speed_below" in when and not speed < float(when["speed_below"]):
                return False
            if "speed_above" in when and not speed > float(when["speed_above"]):
                return False
        if "connections_below" in when and not dl["connections"] < int(when["connections_below"]):
            return False
        progress = dl["progress"]
        if "min_progress" in when and progress < float(when["min_progress"]):
            return False
        if "max_progress" in when and progress > float(when["max_progress"]):
            return False
        if "min_size" in when and dl["total"] < int(when["min_size"]):
            return False
        if when.get("torrent_only") and not dl["isTorrent"]:
            return False
        if when.get("http_only") and dl["isTorrent"]:
            return False
        if pattern := when.get("name_matches"):
            try:
                if not re.search(str(pattern), dl["name"]):
                    return False
            except re.error:
                return False
        return True

    async def evaluate(self, snapshot: dict, dt: float) -> None:
        now = snapshot.get("ts") or time.time()
        seen: set[str] = set()
        rules = self.active_rules() if self.enabled else []

        for dl in snapshot["downloads"]:
            gid = dl["gid"]
            seen.add(gid)
            tracker = self.tracked.setdefault(gid, Tracker(first_seen=now))
            if dl["status"] == "active":
                if not tracker.active_since:
                    tracker.active_since = now
            else:
                # Leaving the active state restarts the grace period, so a
                # pause/resume cycle is not immediately re-judged either.
                tracker.active_since = 0.0
            for rule in rules:
                name = rule["name"]
                st = tracker.state(name)
                if st.acting:
                    continue
                when = rule.get("when") or {}
                if not self._matches(when, dl, tracker, now):
                    st.elapsed = 0.0
                    continue
                cooldown = float(rule.get("cooldown_seconds", 0) or 0)
                if st.last_trigger and now - st.last_trigger < cooldown:
                    continue
                max_triggers = int(rule.get("max_triggers", 0) or 0)
                if max_triggers and st.triggers >= max_triggers:
                    continue
                st.elapsed += max(dt, 0.0)
                if st.elapsed + 1e-6 < float(when.get("for_seconds", 0) or 0):
                    continue
                st.elapsed = 0.0
                st.triggers += 1
                st.last_trigger = now
                st.acting = True
                judged = dict(dl)
                judged["judgedSpeed"] = self.speed_of(dl, when)
                asyncio.create_task(self._run_action(rule, judged, st))

        for gid in list(self.tracked):
            if gid not in seen:
                self.tracked.pop(gid, None)

    # ---- actions ---------------------------------------------------------
    async def _run_action(self, rule: dict, dl: dict, st: TrackState) -> None:
        gid = dl["gid"]
        name = rule["name"]
        action = rule.get("action", "log_only")
        try:
            detail = await self._dispatch(rule, action, dl)
            entry = {
                "ts": time.time(),
                "rule": name,
                "gid": gid,
                "name": dl["name"],
                "action": action,
                "speed": dl.get("judgedSpeed", dl["downloadSpeed"]),
                "detail": detail,
            }
            self.trigger_log.insert(0, entry)
            del self.trigger_log[200:]
            self.store.add_event(
                "rule",
                f"[{name}] {ACTION_PHRASES.get(action, action)} {dl['name']}"
                + (f" ({detail})" if detail else ""),
                gid=gid,
                rule=name,
                action=action,
                speed=dl.get("judgedSpeed", dl["downloadSpeed"]),
            )
        except Exception as exc:
            self.store.add_event(
                "error", f"[{name}] {action} failed on {dl['name']}: {exc}", gid=gid, rule=name
            )
        finally:
            st.acting = False

    async def _dispatch(self, rule: dict, action: str, dl: dict) -> str:
        gid = dl["gid"]
        speed = dl.get("judgedSpeed", dl["downloadSpeed"])
        if action == "log_only":
            return f"{speed} B/s"

        if action in ("pause_resume", "force_pause_resume"):
            force = action == "force_pause_resume"
            preserve = bool(rule.get("preserve_slot", True))
            # Pausing frees a concurrency slot, and aria2 immediately starts the
            # next queued download. Remember who was running so the slot can be
            # taken back for *this* download rather than handed away.
            before = await self._active_gids() if preserve else set()
            await self.rpc.pause(gid, force=force)
            await asyncio.sleep(float(rule.get("resume_after_seconds", 1.5) or 0))
            await self.rpc.unpause(gid)
            note = f"was {speed} B/s"
            if preserve:
                note += f"; {await self._reclaim_slot(gid, before)}"
            return note

        if action == "stop":
            await self.rpc.pause(gid, force=bool(rule.get("force", False)))
            return "paused, left paused"

        if action == "set_option":
            options = {k: stringify(v) for k, v in (rule.get("options") or {}).items()}
            await self.rpc.change_option(gid, options)
            return ", ".join(f"{k}={v}" for k, v in options.items())

        if action == "restart":
            return await self._restart(gid)

        raise ValueError(f"unknown action {action!r}")

    async def _active_gids(self) -> set[str]:
        try:
            active = await self.rpc.call("aria2.tellActive", ["gid"])
        except (Aria2Error, OSError):
            return set()
        return {row.get("gid", "") for row in (active or []) if row.get("gid")}

    async def _reclaim_slot(
        self, gid: str, before_active: set[str], attempts: int = 6
    ) -> str:
        """Make sure the download we just resumed is the one that runs again.

        With max-concurrent-downloads saturated, the download that grabbed the
        freed slot has to be bounced: pausing it frees the slot, and with our
        download moved to the head of the queue aria2 promotes ours instead. The
        bounced download then goes back to waiting, next in line.
        """
        for attempt in range(attempts):
            try:
                status = (await self.rpc.tell_status(gid, ["status"])).get("status")
            except Aria2Error:
                return "download is gone"
            if status == "active":
                return "kept its slot" if attempt == 0 else "slot reclaimed"
            if status not in ("waiting", "paused"):
                return f"ended up {status}"

            with_position = True
            try:
                await self.rpc.change_position(gid, 0, "POS_SET")
            except (Aria2Error, OSError):
                with_position = False

            intruders = [
                g for g in await self._active_gids()
                if g not in before_active and g != gid
            ]
            if intruders and with_position:
                victim = intruders[0]
                try:
                    await self.rpc.pause(victim)
                    # Pausing put the victim at the head of the queue; put ours back.
                    await self.rpc.change_position(gid, 0, "POS_SET")
                    await asyncio.sleep(0.6)
                finally:
                    try:
                        await self.rpc.unpause(victim)
                    except (Aria2Error, OSError):
                        pass
            await asyncio.sleep(0.5)
        return "could not get its slot back — it is queued next"

    async def _restart(self, gid: str) -> str:
        """Remove the download and re-add it with the same URIs and options."""
        uris = [u["uri"] for u in (await self.rpc.get_uris(gid) or []) if u.get("uri")]
        if not uris:
            raise ValueError("no re-addable URIs (torrent/metadata download)")
        options = await self.rpc.get_option(gid) or {}
        keep = (
            "dir",
            "out",
            "referer",
            "user-agent",
            "header",
            "split",
            "max-connection-per-server",
            "min-split-size",
            "max-download-limit",
            "all-proxy",
            "http-user",
            "http-passwd",
            "check-integrity",
            "continue",
        )
        slim = {k: options[k] for k in keep if options.get(k) not in (None, "")}
        try:
            await self.rpc.remove(gid, force=True)
        except Exception:
            pass
        try:
            await self.rpc.remove_result(gid)
        except Exception:
            pass
        new_gid = await self.rpc.add_uri(uris, slim)
        return f"re-added as {new_gid}"

    # ---- exposure --------------------------------------------------------
    def public_state(self) -> dict:
        """Per-download rule progress, for the UI's countdown badges."""
        rules = {r["name"]: r for r in self.active_rules()}
        out: dict[str, Any] = {"enabled": self.enabled, "downloads": {}}
        for gid, tracker in self.tracked.items():
            entries = {}
            for name, st in tracker.rules.items():
                rule = rules.get(name)
                if not rule:
                    continue
                threshold = float((rule.get("when") or {}).get("for_seconds", 0) or 0)
                if st.elapsed <= 0 and st.triggers == 0 and not st.acting:
                    continue
                entries[name] = {
                    "elapsed": round(st.elapsed, 1),
                    "threshold": threshold,
                    "triggers": st.triggers,
                    "acting": st.acting,
                }
            if entries:
                out["downloads"][gid] = entries
        return out
