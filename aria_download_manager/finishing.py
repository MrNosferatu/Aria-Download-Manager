"""What happens when a download finishes: extract an archive, run a command.

The rules engine (rules.py) fires these once per download, the moment it
finishes (``when: {event: finished}``).

Extraction picks the tool for the format (7z, unrar, tar, bsdtar) and never
asks for a password: an archive that needs one fails, says so, and is left as
it is. It extracts beside the archive into a hidden working folder, then
moves the result into place: a single top-level folder as it is, anything
else into a folder named after the archive, so nothing is dumped loose and
nothing is nested twice. A split archive (name.part1.rar, name.7z.001,
name.rar + name.r00) is extracted from its first part, once no part of it is
still downloading; whichever part finishes last sets it off. Afterwards the
archive (every part of it) can be deleted.

A command runs through ``sh -c`` with ``{path}``, ``{dir}``, ``{name}`` and
``{gid}`` filled in, each quoted, so a file name cannot break out of it; the
same values are in its environment as ARIA_PATH, ARIA_DIR, ARIA_NAME,
ARIA_GID.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import re
import shlex
import shutil
import time
from pathlib import Path
from typing import Callable

TAR_SUFFIXES = (".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tbz",
                ".tar.zst", ".tzst", ".tar.lz", ".tar.lzma")
#: A wrong password on purpose: an archive that needs one fails at once
#: instead of waiting for someone to type it (stdin is closed as well).
NO_PASSWORD = "-paria-download-manager-no-password"


def archive_kind(name: str) -> str | None:
    """"rar", "7z", "zip" or "tar" for an archive's file name (any part of a
    split one), else None."""
    low = name.lower()
    if re.search(r"\.part\d+\.rar$", low) or low.endswith(".rar") or re.search(r"\.r\d\d$", low):
        return "rar"
    if re.search(r"\.7z(\.\d{3})?$", low):
        return "7z"
    if re.search(r"\.zip(\.\d{3})?$", low):
        return "zip"
    if low.endswith(TAR_SUFFIXES):
        return "tar"
    return None


def stem_of(name: str) -> str:
    """The archive's name without its archive suffixes: what its folder is called."""
    low = name.lower()
    for pattern in (r"\.part\d+\.rar$", r"\.r\d\d$", r"\.(7z|zip)\.\d{3}$"):
        if m := re.search(pattern, low):
            return name[:m.start()]
    for suffix in sorted(TAR_SUFFIXES + (".rar", ".7z", ".zip"), key=len, reverse=True):
        if low.endswith(suffix):
            return name[:-len(suffix)]
    return name


def first_part(path: Path) -> Path:
    """The part an extraction starts from: name.part1.rar, name.7z.001,
    name.rar (for the old name.r00 style); the archive itself when whole."""
    name = path.name
    if m := re.search(r"\.part(\d+)\.rar$", name, re.I):
        width = len(m.group(1))
        return path.with_name(f"{name[:m.start()]}.part{1:0{width}d}.rar")
    if re.search(r"\.r\d\d$", name, re.I):
        return path.with_name(f"{name[:-4]}.rar")
    if m := re.search(r"\.(7z|zip)\.\d{3}$", name, re.I):
        return path.with_name(f"{name[:m.end(1)]}.001")
    return path


def parts_of(first: Path) -> list[Path]:
    """Every part of the archive that starts at ``first`` found beside it."""
    stem = stem_of(first.name)
    out = []
    for sibling in first.parent.iterdir() if first.parent.is_dir() else []:
        if sibling.is_file() and archive_kind(sibling.name) and stem_of(sibling.name) == stem \
                and first_part(sibling) == first:
            out.append(sibling)
    return sorted(out) or ([first] if first.exists() else [])


def archives_in(path: Path) -> list[Path]:
    """The archives a finished download holds, by their first parts: the file
    itself, or (a torrent's folder) every archive inside it."""
    if path.is_dir():
        found = [p for p in sorted(path.rglob("*")) if p.is_file() and archive_kind(p.name)]
    elif path.is_file() and archive_kind(path.name):
        found = [path]
    else:
        found = []
    firsts: list[Path] = []
    for p in found:
        f = first_part(p)
        if f not in firsts:
            firsts.append(f)
    return firsts


def tool_argv(archive: Path, kind: str, dest: Path) -> list[str] | None:
    """How to extract ``archive`` into ``dest`` with what is installed."""
    have = shutil.which
    if kind == "rar" and have("unrar"):
        return ["unrar", "x", "-o+", "-p-", "-y", str(archive), str(dest) + "/"]
    if kind == "tar" and have("tar"):
        return ["tar", "-xf", str(archive), "-C", str(dest)]
    seven = have("7z") or have("7za") or have("7zz")
    if seven:
        return [seven, "x", "-y", NO_PASSWORD, f"-o{dest}", str(archive)]
    if have("bsdtar"):
        return ["bsdtar", "-xf", str(archive), "-C", str(dest)]
    if kind == "zip" and have("unzip"):
        return ["unzip", "-o", "-P", "", str(archive), "-d", str(dest)]
    return None


def unique(path: Path) -> Path:
    """``path``, or "name (2)", "name (3)"… if something is already there."""
    if not path.exists():
        return path
    for n in range(2, 1000):
        candidate = path.with_name(f"{path.name} ({n})")
        if not candidate.exists():
            return candidate
    raise OSError(f"too many folders named {path.name}")


def fill(command: str, values: dict[str, str]) -> str:
    """The command with {path} {dir} {name} {gid} replaced, each shell-quoted;
    any other braces (awk's, say) are left alone."""
    return re.sub(r"\{(path|dir|name|gid)\}", lambda m: shlex.quote(values.get(m.group(1), "")), command)


class Finisher:
    def __init__(self, on_event: Callable[..., None] = lambda *a, **k: None):
        self.on_event = on_event
        #: Recent jobs, newest first: what is extracting or running, and how
        #: the last ones went. Shown in the state so the lists can say so.
        self.jobs: list[dict] = []
        self._lock = asyncio.Lock()
        self._done: set[str] = set()

    @property
    def busy(self) -> bool:
        return any(j["status"] == "running" for j in self.jobs)

    def public_state(self) -> list[dict]:
        return self.jobs[:12]

    def _job(self, dl: dict, action: str, what: str) -> dict:
        job = {"gid": dl.get("gid", ""), "name": dl.get("name", ""), "action": action,
               "what": what, "status": "running", "message": "", "ts": time.time()}
        self.jobs.insert(0, job)
        del self.jobs[40:]
        return job

    @staticmethod
    def root_of(dl: dict) -> Path:
        """Where a finished download's files are: an aria2 torrent's folder
        (its path is only its first file), else its own path."""
        if dl.get("isTorrent") and dl.get("dir") and dl.get("name"):
            folder = Path(dl["dir"]) / dl["name"]
            if folder.exists():
                return folder
        return Path(dl.get("path") or "")

    # ---- extracting -------------------------------------------------------
    async def extract(self, dl: dict, delete_archive: bool = False, pending: list[str] | None = None) -> str:
        archives = archives_in(self.root_of(dl))
        if not archives:
            return "nothing to extract"
        notes = []
        for first in archives:
            notes.append(await self._extract_one(dl, first, delete_archive, pending or []))
        return "; ".join(notes)

    async def _extract_one(self, dl: dict, first: Path, delete_archive: bool, pending: list[str]) -> str:
        key = str(first)
        if key in self._done:
            return f"{first.name} already extracted"
        stem = stem_of(first.name)
        # A part still downloading (here, or queued in the manager) holds the
        # whole set back; the part that finishes last sets it off.
        parts = parts_of(first)
        if not first.exists() or any(Path(str(p) + ".aria2").exists() for p in parts) \
                or any(archive_kind(n) and stem_of(n) == stem for n in pending):
            return f"{stem}: waiting for the remaining parts"
        kind = archive_kind(first.name) or "zip"
        work = first.parent / f".{stem}.extracting"
        argv = tool_argv(first, kind, work)
        if argv is None:
            raise RuntimeError("no extraction tool found (install 7zip, unrar or libarchive)")
        if shutil.which("nice"):
            argv = ["nice", "-n", "10"] + argv
        job = self._job(dl, "extract", first.name)
        async with self._lock:
            self._done.add(key)
            shutil.rmtree(work, ignore_errors=True)
            work.mkdir(parents=True)
            try:
                proc = await asyncio.create_subprocess_exec(
                    *argv, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.STDOUT, cwd=str(first.parent))
                out, _ = await proc.communicate()
                text = out.decode("utf-8", "replace")
                if proc.returncode != 0:
                    if re.search(r"(?i)wrong password|encrypted|password", text):
                        raise RuntimeError(f"{first.name} is password-protected, so it was skipped")
                    if re.search(r"(?i)cannot find volume|missing volume|unexpected end", text):
                        raise RuntimeError(f"{first.name} is missing a part")
                    tail = " ".join(text.strip().splitlines()[-2:])[:200]
                    raise RuntimeError(f"{first.name} couldn’t be extracted (exit {proc.returncode}): {tail}")
                entries = [p for p in work.iterdir()]
                if len(entries) == 1 and entries[0].is_dir():
                    target = unique(first.parent / entries[0].name)
                    entries[0].rename(target)
                    work.rmdir()
                else:
                    target = unique(first.parent / stem)
                    work.rename(target)
            except BaseException as exc:
                self._done.discard(key)
                shutil.rmtree(work, ignore_errors=True)
                job.update(status="error", message=str(exc))
                raise
        removed = 0
        if delete_archive:
            for part in parts:
                with contextlib.suppress(OSError):
                    part.unlink()
                    removed += 1
        note = f"extracted {first.name} into {target.name}" + (f", archive deleted" if removed else "")
        job.update(status="done", message=note)
        return note

    # ---- running a command -------------------------------------------------
    async def run(self, dl: dict, command: str, timeout: float = 3600) -> str:
        path = str(self.root_of(dl))
        values = {"path": path, "dir": str(dl.get("dir") or os.path.dirname(path)),
                  "name": str(dl.get("name") or os.path.basename(path)), "gid": str(dl.get("gid") or "")}
        line = fill(command, values)
        env = dict(os.environ, ARIA_PATH=values["path"], ARIA_DIR=values["dir"],
                   ARIA_NAME=values["name"], ARIA_GID=values["gid"])
        job = self._job(dl, "run", command)
        try:
            proc = await asyncio.create_subprocess_exec(
                "sh", "-c", line, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT, env=env, cwd=values["dir"] if os.path.isdir(values["dir"]) else None)
            try:
                out, _ = await asyncio.wait_for(proc.communicate(), timeout)
            except asyncio.TimeoutError:
                proc.kill()
                raise RuntimeError(f"stopped after running for {int(timeout)} s")
            tail = " ".join(out.decode("utf-8", "replace").strip().splitlines()[-2:])[:200]
            if proc.returncode != 0:
                raise RuntimeError(f"exit {proc.returncode}" + (f": {tail}" if tail else ""))
        except BaseException as exc:
            job.update(status="error", message=str(exc))
            raise
        note = "done" + (f": {tail}" if tail else "")
        job.update(status="done", message=note)
        return note
