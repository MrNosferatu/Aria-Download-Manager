"""What happens when a download finishes (finishing.py, and the finish rules
in rules.py): extracting real archives with the tools installed, running a
command, and firing once per download that finishes.

    python3 tests/test_finishing.py
"""

from __future__ import annotations

import asyncio
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from aria_download_manager import finishing as fin  # noqa: E402
from aria_download_manager.rules import RuleEngine, finished  # noqa: E402
from tests.harness import check, summary  # noqa: E402

SEVEN = shutil.which("7z") or shutil.which("7za") or shutil.which("7zz")


def test_names() -> None:
    print("\nnaming the parts of an archive")
    kinds = [fin.archive_kind(n) for n in ["a.zip", "a.7z", "a.part2.rar", "a.r01", "a.tar.zst", "a.7z.003", "a.mkv"]]
    check("archives are known by their names, parts included",
          kinds == ["zip", "7z", "rar", "rar", "tar", "7z", None], str(kinds))
    stems = [fin.stem_of(n) for n in ["Show.S01.part03.rar", "Pack.tar.gz", "Big.7z.002", "Old.r00", "x.zip"]]
    check("and each one's folder is named without them",
          stems == ["Show.S01", "Pack", "Big", "Old", "x"], str(stems))
    firsts = [fin.first_part(Path("/d") / n).name for n in ["S.part03.rar", "S.part01.rar", "B.7z.002", "O.r04", "z.zip"]]
    check("any part leads to the one extraction starts from",
          firsts == ["S.part01.rar", "S.part01.rar", "B.7z.001", "O.rar", "z.zip"], str(firsts))
    filled = fin.fill("""mv {path} "$HOME/x" && echo {name} | awk '{print $1}'""",
                      {"path": "/d/it's a file.zip", "name": "a b"})
    check("a command gets the values quoted and keeps its own braces",
          filled == """mv '/d/it'"'"'s a file.zip' "$HOME/x" && echo 'a b' | awk '{print $1}'""", filled)


def make(tmp: Path, name: str, files: dict[str, str]) -> Path:
    """Write `files` (relative path -> text) into a fresh folder."""
    src = tmp / f"src-{name}"
    for rel, text in files.items():
        (src / rel).parent.mkdir(parents=True, exist_ok=True)
        (src / rel).write_text(text)
    return src


async def test_extract(tmp: Path) -> None:
    print("\nextracting (real archives)")
    if not SEVEN:
        print("  (7z is not installed: skipping)")
        return
    finisher = fin.Finisher()
    dl_dir = tmp / "dl"
    dl_dir.mkdir()

    def dl(path: Path) -> dict:
        return {"gid": path.name, "name": path.name, "path": str(path), "dir": str(path.parent)}

    # A zip with one top folder comes out as that folder, not nested twice.
    src = make(tmp, "top", {"Album/01.flac": "a", "Album/02.flac": "b"})
    archive = dl_dir / "Album-2024.zip"
    subprocess.run([SEVEN, "a", "-bd", str(archive), "Album"], cwd=src, check=True, capture_output=True)
    note = await finisher.extract(dl(archive))
    check("one top folder comes out as itself", (dl_dir / "Album" / "02.flac").is_file()
          and not (dl_dir / "Album-2024").exists(), note)
    check("and the archive is kept unless asked", archive.exists())

    # Loose files go into a folder named after the archive.
    src = make(tmp, "loose", {"readme.txt": "r", "bin/tool": "t"})
    archive = dl_dir / "Tool v2.7z"
    subprocess.run([SEVEN, "a", "-bd", str(archive), "."], cwd=src, check=True, capture_output=True)
    await finisher.extract(dl(archive), delete_archive=True)
    check("loose files go into a folder named after the archive", (dl_dir / "Tool v2" / "bin" / "tool").is_file())
    check("deleted afterwards when asked", not archive.exists())
    check("no working folder is left behind", not any(p.name.startswith(".") for p in dl_dir.iterdir()))

    # A second "Tool v2" gets its own name rather than mixing in.
    src = make(tmp, "loose2", {"other.txt": "o"})
    archive = dl_dir / "Tool v2.tar.gz"
    subprocess.run(["tar", "-czf", str(archive), "-C", str(src), "."], check=True)
    await finisher.extract(dl(archive))
    check("a tarball with a taken name gets \"(2)\"", (dl_dir / "Tool v2 (2)" / "other.txt").is_file())

    # A password-protected one fails at once, without asking, and is left alone.
    src = make(tmp, "secret", {"s.txt": "s"})
    archive = dl_dir / "secret.7z"
    subprocess.run([SEVEN, "a", "-bd", "-pHUNTER2", "-mhe=on", str(archive), "."], cwd=src, check=True,
                   capture_output=True)
    try:
        await asyncio.wait_for(finisher.extract(dl(archive)), 30)
        failed = ""
    except RuntimeError as exc:
        failed = str(exc)
    check("a password-protected archive fails, saying so", "password" in failed, failed)
    check("and is left as it was, with nothing half-extracted", archive.exists()
          and not (dl_dir / "secret").exists() and not (dl_dir / ".secret.extracting").exists())
    check("the job list says how it went",
          finisher.jobs[0]["status"] == "error" and "password" in finisher.jobs[0]["message"])

    # A split archive waits for its parts.
    src = make(tmp, "split", {"big.bin": "x" * 300_000})
    subprocess.run([SEVEN, "a", "-bd", "-mx0", "-v100k", str(dl_dir / "Big.7z"), "big.bin"], cwd=src, check=True,
                   capture_output=True)
    parts = sorted(dl_dir.glob("Big.7z.*"))
    check("(a three-part 7z was made)", len(parts) >= 3, str(parts))
    note = await finisher.extract(dl(parts[0]), pending=["Big.7z.003"])
    check("a split archive waits while a part is still to come", "waiting" in note and not (dl_dir / "Big").exists(), note)
    control = Path(str(parts[1]) + ".aria2")
    control.write_text("")
    note = await finisher.extract(dl(parts[-1]))
    check("or while a part is still being written", "waiting" in note, note)
    control.unlink()
    note = await finisher.extract(dl(parts[-1]), delete_archive=True)
    check("the last part to finish sets it off, from the first part", (dl_dir / "Big" / "big.bin").is_file()
          or (dl_dir / "big.bin").is_file(), note)
    check("and deleting takes every part", not any(dl_dir.glob("Big.7z.*")))
    note = await finisher.extract(dl(parts[0]))
    check("nothing is extracted twice", note in ("nothing to extract",) or "already" in note, note)

    # A torrent's folder: every archive inside it.
    folder = dl_dir / "Season Pack"
    folder.mkdir()
    for n in ("e1", "e2"):
        src = make(tmp, n, {f"{n}.mkv": n})
        subprocess.run([SEVEN, "a", "-bd", str(folder / f"{n}.zip"), "."], cwd=src, check=True, capture_output=True)
    note = await finisher.extract({"gid": "t", "name": "Season Pack", "dir": str(dl_dir),
                                   "path": str(folder / "e1.zip"), "isTorrent": True})
    check("a torrent's folder has each archive in it extracted",
          (folder / "e1" / "e1.mkv").is_file() and (folder / "e2" / "e2.mkv").is_file(), note)


async def test_run(tmp: Path) -> None:
    print("\nrunning a command")
    finisher = fin.Finisher()
    target = tmp / "ran.txt"
    weird = tmp / "it's $(here).iso"
    weird.write_text("x")
    note = await finisher.run({"gid": "g1", "name": weird.name, "path": str(weird), "dir": str(tmp)},
                              f"printf '%s|%s|%s' {{name}} \"$ARIA_GID\" {{path}} > {target}")
    check("its values are filled in, quoted, and in its environment",
          target.read_text() == f"{weird.name}|g1|{weird}", target.read_text())
    try:
        await finisher.run({"gid": "g2", "name": "n", "path": str(tmp), "dir": str(tmp)}, "echo oops; exit 3")
        failed = ""
    except RuntimeError as exc:
        failed = str(exc)
    check("a failing command says how it ended", failed == "exit 3: oops", failed)


class Store:
    def __init__(self):
        self.events = []

    def add_event(self, level, message, **kw):
        self.events.append((level, message))


class FakeFinisher:
    def __init__(self):
        self.calls = []

    async def extract(self, dl, delete_archive, pending):
        self.calls.append(("extract", dl["name"], delete_archive, list(pending)))
        return "extracted"

    async def run(self, dl, command):
        self.calls.append(("run", dl["name"], command))
        return "done"


class Cfg:
    def __init__(self, rules):
        self.rules = rules
        self.data = {}

    def get(self, key, default=None):
        return default


def row(gid, name, status, **kw):
    return {"gid": gid, "name": name, "status": status, "downloadSpeed": 0, "connections": 0,
            "progress": 100.0 if status == "complete" else 10.0, "total": 1000, "isTorrent": False, **kw}


async def test_rules() -> None:
    print("\nfinish rules")
    rules = [
        {"name": "unzip", "enabled": True, "when": {"event": "finished", "kinds": ["archive"]},
         "action": "extract", "delete_archive": True},
        {"name": "notify", "enabled": True, "when": {"event": "finished", "name_matches": r"\.iso$"},
         "action": "run", "command": "notify-send {name}"},
    ]
    engine = RuleEngine(Cfg(rules), rpc=None, store=Store())
    engine.finisher = FakeFinisher()
    engine.category_of = lambda name: "archive" if name.endswith(".zip") else "other"
    calls = engine.finisher.calls

    await engine.evaluate({"ts": 1, "downloads": [row("a", "old.zip", "complete"), row("b", "new.zip", "active"),
                                                  row("c", "disk.iso", "active"), row("d", "next.zip", "waiting")]}, 1)
    await asyncio.sleep(0.05)
    check("what had finished before the manager started fires nothing", calls == [], str(calls))
    check("and a finish rule never acts on running downloads", not engine.public_state()["downloads"])

    await engine.evaluate({"ts": 2, "downloads": [row("a", "old.zip", "complete"), row("b", "new.zip", "complete"),
                                                  row("c", "disk.iso", "active"), row("d", "next.zip", "waiting")]}, 1)
    await asyncio.sleep(0.05)
    check("a download that finishes fires the rule for its type, once",
          calls == [("extract", "new.zip", True, ["disk.iso", "next.zip"])], str(calls))
    await engine.evaluate({"ts": 3, "downloads": [row("b", "new.zip", "complete"), row("c", "disk.iso", "complete"),
                                                  row("d", "next.zip", "waiting")]}, 1)
    await asyncio.sleep(0.05)
    check("not again on the next tick, and the other rule takes its own match",
          calls[1:] == [("run", "disk.iso", "notify-send {name}")], str(calls))
    seeding = row("t", "pack.zip", "active", isTorrent=True, seeder=True)
    check("a seeding torrent counts as finished", finished(seeding) and not finished(row("m", "m", "complete", isMetadata=True)))
    await engine.evaluate({"ts": 4, "downloads": [seeding]}, 1)
    await asyncio.sleep(0.05)
    check("and fires when it starts seeding", calls[-1][:2] == ("extract", "pack.zip"), str(calls))
    check("the log records what was done", any("[unzip] extracted pack.zip" in m for _, m in engine.store.events))

    problems = engine.validate({"name": "x", "when": {"event": "finished"}, "action": "pause_resume"})
    check("a finish rule cannot pause", any("finished downloads can only" in p for p in problems), str(problems))
    check("run needs its command", engine.validate({"name": "x", "when": {"event": "finished"}, "action": "run"})
          == ["action run needs a command"])
    check("a finish rule needs no speed", engine.validate({"name": "x", "when": {"event": "finished"}, "action": "extract"}) == [])
    check("and extract is only for finished downloads",
          any("finished downloads" in p for p in engine.validate({"name": "x", "when": {"speed_below": 1}, "action": "extract"})))


async def test_after_all(tmp: Path) -> None:
    print("\nshut down / suspend once everything is done")
    from aria_download_manager.afterall import AfterAll, downloading
    log = tmp / "power.log"

    class Settings:
        def get(self, key, default=None):
            return {"finish.countdown_seconds": 0.4,
                    "finish.shutdown_command": ["sh", "-c", f"echo shutdown >> {log}"],
                    "finish.suspend_command": ["sh", "-c", f"echo suspend >> {log}"]}.get(key, default)

    class Snap:
        snapshot = {"downloads": []}

    store = Snap()
    events = []
    jobs = fin.Finisher()
    after = AfterAll(Settings(), store, jobs, lambda level, message, **kw: events.append(message))
    busy = {"downloads": [row("a", "a.zip", "active"), row("p", "p.iso", "paused")]}
    store.snapshot = busy
    after.set("shutdown")
    check("while something downloads it only waits", after.status()["action"] == "shutdown"
          and after.status()["deadline"] is None)
    check("paused downloads and seeding torrents do not hold it back",
          not downloading({"downloads": [row("p", "p", "paused"), row("s", "s", "active", seeder=True)]}))

    store.snapshot = {"downloads": [row("a", "a.zip", "complete"), row("p", "p.iso", "paused")]}
    after.observe(store.snapshot)
    check("once everything is done it counts down, in the state", after.status()["secondsLeft"] is not None
          and any("Shutting down in" in e for e in events))
    store.snapshot = busy
    after.observe(busy)
    check("a download starting puts it back to waiting", after.status()["deadline"] is None)
    await asyncio.sleep(0.6)
    check("and nothing runs meanwhile", not log.exists())

    store.snapshot = {"downloads": []}
    after.observe(store.snapshot)
    await asyncio.sleep(0.8)
    check("when the minute is up it runs, once", log.exists() and log.read_text() == "shutdown\n",
          log.read_text() if log.exists() else "")
    check("and the choice is gone: it never acts again by surprise", after.status()["action"] == "")
    after.observe(store.snapshot)
    await asyncio.sleep(0.6)
    check("(even with nothing downloading)", log.read_text() == "shutdown\n")

    after.set("suspend")
    check("set with nothing downloading, it counts down at once", after.status()["deadline"] is not None)
    after.set("")
    await asyncio.sleep(0.6)
    check("Cancel stops it", log.read_text() == "shutdown\n" and after.status()["action"] == "")

    jobs.jobs.insert(0, {"gid": "x", "status": "running"})
    after.set("suspend")
    check("an extraction still running holds it back", after.status()["deadline"] is None)
    jobs.jobs[0]["status"] = "done"
    after.observe(store.snapshot)
    await asyncio.sleep(0.8)
    check("and it goes once that is done", log.read_text() == "shutdown\nsuspend\n")
    try:
        after.set("reboot")
        refused = False
    except ValueError:
        refused = True
    check("only shut down or suspend are offered", refused)


async def main() -> int:
    test_names()
    with tempfile.TemporaryDirectory(prefix="aria-finish-test-") as tmp:
        await test_extract(Path(tmp))
        await test_run(Path(tmp))
        await test_after_all(Path(tmp))
    await test_rules()
    return summary()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
