"""Put each download in a folder that matches what it is.

aria2 has one download folder. This sorts into subfolders of it by file type —
archives, music, video, images, and everything else — by looking at the name
before the download starts:

* a plain URL: the filename it ends in (or the `out` option, when one is given);
* a .torrent or .metalink handed to the manager: its file list, decoded here,
  categorised by the largest file in it;
* a magnet: nothing is known until its metadata arrives, so the torrent it turns
  into is paused for the moment it takes to set the folder, then resumed. Moving
  it later would leave the empty files aria2 had already created behind in the
  wrong folder.

A folder the caller chose explicitly always wins: this only fills in a blank.
An add that asks for it (``auto-route``, the dialogs' "Auto · by type") is
sorted even with sorting turned off in Settings. A link whose name says
nothing (``download?id=…``) has its real filename asked of the server before
it is added (see api.py), so it starts in its type's folder.
"""

from __future__ import annotations

import base64
import os
import posixpath
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit

#: The add option asking for sorting by type whatever Settings say.
AUTO_ROUTE = "auto-route"

#: Every download lands in exactly one of these.
CATEGORIES = ("archive", "music", "video", "image", "other")

#: Subfolder per category, under aria2's download folder. Blank means the
#: download folder itself, which is what "other" does unless it is given one.
DEFAULT_FOLDERS = {
    "archive": "Archives",
    "music": "Music",
    "video": "Video",
    "image": "Images",
    "other": "",
}

DEFAULT_EXTENSIONS = {
    "archive": [
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst", "tgz", "tbz2",
        "txz", "iso", "dmg", "pkg", "deb", "rpm", "apk", "cab", "lz4", "lzma",
    ],
    "music": [
        "mp3", "flac", "wav", "aac", "ogg", "oga", "opus", "m4a", "wma", "aiff",
        "alac", "ape", "mid", "midi",
    ],
    "video": [
        "mkv", "mp4", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg",
        "ts", "m2ts", "vob", "rmvb", "3gp", "ogv",
    ],
    "image": [
        "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", "tif", "svg", "heic",
        "heif", "avif", "ico", "psd", "raw", "cr2", "nef",
    ],
}


def extension_of(name: str) -> str:
    return os.path.splitext(str(name or "").strip())[1].lstrip(".").lower()


def name_from_uri(uri: str) -> str:
    """The filename a URL ends in, with its query and escaping taken off."""
    text = str(uri or "").strip()
    if not text or text.lower().startswith("magnet:"):
        return ""
    path = urlsplit(text).path if "://" in text else text.split("?")[0]
    return unquote(posixpath.basename(path.rstrip("/")))


# ---------------------------------------------------------------- bencode
def _bdecode(data: bytes, at: int = 0):
    """Just enough bencode to read a .torrent's file list."""
    kind = data[at:at + 1]
    if kind == b"i":
        end = data.index(b"e", at)
        return int(data[at + 1:end]), end + 1
    if kind == b"l":
        at += 1
        out = []
        while data[at:at + 1] != b"e":
            item, at = _bdecode(data, at)
            out.append(item)
        return out, at + 1
    if kind == b"d":
        at += 1
        out = {}
        while data[at:at + 1] != b"e":
            key, at = _bdecode(data, at)
            value, at = _bdecode(data, at)
            out[key if isinstance(key, bytes) else str(key).encode()] = value
        return out, at + 1
    colon = data.index(b":", at)
    length = int(data[at:colon])
    start = colon + 1
    return data[start:start + length], start + length


def torrent_files(payload: bytes) -> list[tuple[str, int]]:
    """(name, size) for every file in a .torrent, or [] if it cannot be read."""
    try:
        meta, _ = _bdecode(payload)
        info = meta[b"info"]
    except Exception:
        return []
    name = (info.get(b"name") or b"").decode("utf-8", "replace")
    files = info.get(b"files")
    if not files:
        return [(name, int(info.get(b"length") or 0))]
    out = []
    for entry in files:
        try:
            parts = [p.decode("utf-8", "replace") for p in entry[b"path"]]
            out.append(("/".join(parts), int(entry.get(b"length") or 0)))
        except Exception:
            continue
    return out


class Router:
    def __init__(self, cfg, rpc, on_event):
        self.cfg = cfg
        self.rpc = rpc
        self.on_event = on_event
        #: Metadata gids whose torrent is still to be placed: gid -> resume?
        self.expected: dict[str, bool] = {}

    # ---- settings ---------------------------------------------------------
    @property
    def enabled(self) -> bool:
        return bool(self.cfg.get("routing.enabled", False))

    def folders(self) -> dict[str, str]:
        saved = self.cfg.get("routing.folders", {}) or {}
        return {key: str(saved.get(key, DEFAULT_FOLDERS[key]) or "") for key in CATEGORIES}

    def extensions(self) -> dict[str, list[str]]:
        saved = self.cfg.get("routing.extensions", {}) or {}
        out = {}
        for key, default in DEFAULT_EXTENSIONS.items():
            values = saved.get(key)
            listed = values if isinstance(values, list) else default
            out[key] = [str(v).strip().lstrip(".").lower() for v in listed if str(v).strip()]
        return out

    def public_state(self) -> dict:
        return {
            "enabled": self.enabled,
            "folders": self.folders(),
            "extensions": self.extensions(),
            "categories": list(CATEGORIES),
            "defaults": {"folders": dict(DEFAULT_FOLDERS), "extensions": dict(DEFAULT_EXTENSIONS)},
            "base": self.base_dir(),
        }

    def save(self, enabled: Any = None, folders: dict | None = None,
             extensions: dict | None = None) -> None:
        for holder in (self.cfg.data, self.cfg._user):
            if not isinstance(holder.get("routing"), dict):
                holder["routing"] = {}
            section = holder["routing"]
            if enabled is not None:
                section["enabled"] = bool(enabled)
            if folders is not None:
                section["folders"] = {
                    key: str(folders.get(key, DEFAULT_FOLDERS[key]) or "") for key in CATEGORIES
                }
            if extensions is not None:
                section["extensions"] = {
                    key: sorted({str(v).strip().lstrip(".").lower()
                                 for v in (extensions.get(key) or []) if str(v).strip()})
                    for key in DEFAULT_EXTENSIONS
                }
        self.cfg.save()

    def base_dir(self) -> str:
        return str((self.cfg.get("aria2.options", {}) or {}).get("dir") or str(Path.home() / "Downloads"))

    # ---- placing ----------------------------------------------------------
    def category_of(self, name: str) -> str:
        extension = extension_of(name)
        if extension:
            for category, values in self.extensions().items():
                if extension in values:
                    return category
        return "other"

    def needs_name(self, uri: str, options: dict) -> bool:
        """A plain link whose name tells nothing: worth asking the server."""
        if options.get("dir") or options.get("out") or not (self.enabled or self.forced(options)):
            return False
        if str(uri).strip().lower().startswith(("magnet:", "data:")):
            return False
        return not extension_of(name_from_uri(uri))

    def category_of_torrent(self, payload: bytes) -> str:
        files = torrent_files(payload)
        if not files:
            return "other"
        # What the torrent mostly is: its biggest file decides, so a video with
        # a stray .nfo beside it is still a video.
        return self.category_of(max(files, key=lambda item: item[1])[0])

    def folder_for(self, category: str, base: str = "") -> str:
        folder = self.folders().get(category, "")
        root = base or self.base_dir()
        if not folder:
            return root
        return folder if os.path.isabs(folder) else os.path.join(root, folder)

    @staticmethod
    def forced(options: dict) -> bool:
        """The add asked to be sorted by type whatever Settings say."""
        return str(options.get(AUTO_ROUTE, "")).lower() == "true"

    def apply(self, options: dict, uris: Any = None, torrent: Any = None) -> dict:
        """Fill in `dir` for a new download, unless one was chosen already."""
        forced = self.forced(options)
        options.pop(AUTO_ROUTE, None)  # the manager's word, not aria2's
        if not (self.enabled or forced) or options.get("dir"):
            return options
        category = None
        if torrent:
            payload = torrent if isinstance(torrent, bytes) else base64.b64decode(torrent, validate=False)
            category = self.category_of_torrent(payload)
        else:
            name = options.get("out") or next(
                (n for n in (name_from_uri(u) for u in (uris or [])) if n), "")
            if name:
                category = self.category_of(name)
        if category is None:
            return options  # a magnet: nothing to go on until its metadata lands
        folder = self.folder_for(category)
        # A category with no folder of its own resolves to the download folder;
        # say nothing rather than pinning aria2's own default into the options.
        if folder and folder != self.base_dir():
            options["dir"] = folder
        return options

    # ---- magnets ----------------------------------------------------------
    def expect(self, gid: str, resume: bool, forced: bool = False) -> None:
        """Watch for the torrent this metadata download turns into."""
        if (self.enabled or forced) and gid:
            self.expected[gid] = resume

    def wants_paused_metadata(self, options: dict, uris: Any) -> bool:
        """Should this add hold its torrent until the folder is known?"""
        if not (self.enabled or self.forced(options)) or options.get("dir") or options.get("pause-metadata"):
            return False
        return any(str(u).strip().lower().startswith("magnet:") for u in (uris or []))

    def observe(self, snapshot: dict) -> None:
        import asyncio

        for row in snapshot.get("downloads", []):
            parent = row.get("following")
            if not parent or parent not in self.expected:
                continue
            if row.get("completed"):
                self.expected.pop(parent, None)  # already downloading; leave it alone
                continue
            resume = self.expected.pop(parent)
            asyncio.get_running_loop().create_task(self._place(row, resume))

    async def _place(self, row: dict, resume: bool) -> None:
        gid = row["gid"]
        try:
            files = await self.rpc.call("aria2.getFiles", gid)
            named = [(f.get("path") or "", int(f.get("length") or 0)) for f in (files or [])]
            category = self.category_of(max(named, key=lambda item: item[1])[0]) if named \
                else self.category_of(row.get("name", ""))
            await self.rpc.change_option(gid, {"dir": self.folder_for(category)})
            if resume and row.get("status") == "paused":
                await self.rpc.unpause(gid)
            self.on_event("info", f"Sorted {row.get('name', gid)} into {category}", gid=gid)
        except Exception as exc:
            self.on_event("error", f"Could not sort {row.get('name', gid)}: {exc}", gid=gid)
            if resume:
                try:
                    await self.rpc.unpause(gid)
                except Exception:
                    pass  # it stays paused; the user can start it
