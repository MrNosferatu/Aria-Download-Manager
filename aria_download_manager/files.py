"""Deleting what a download left on disk.

aria2 removes downloads from its own lists but never touches the bytes, so a
stopped or removed download leaves its part file — and its `.aria2` control
file — behind forever. Everything here is about cleaning that up without ever
deleting more than the download actually owned.
"""

from __future__ import annotations

from pathlib import Path


def control_file(path: str) -> str:
    """aria2 parks resume state next to the file as `<name>.aria2`."""
    return path + ".aria2"


def candidates(paths: list[str]) -> list[str]:
    """Every path a download owns: its files, plus their control files."""
    out: list[str] = []
    for path in paths:
        if not path:
            continue
        out.append(path)
        out.append(control_file(path))
    # Keep order, drop repeats — torrents can list the same path twice.
    seen: set[str] = set()
    return [p for p in out if not (p in seen or seen.add(p))]


def _is_deletable(path: Path) -> bool:
    """Regular files and symlinks only.

    A directory here would mean aria2 handed us something unexpected, and
    recursing on that guess is how a download manager eats someone's home
    directory.
    """
    try:
        return path.is_file() or path.is_symlink()
    except OSError:
        return False


def delete(paths: list[str], roots: list[str] | None = None) -> dict:
    """Delete a download's files. Returns what happened, per path.

    `roots` confines the deletion: a path outside every root is refused rather
    than deleted. Callers pass the download's own directory plus the configured
    download dir, so a hand-edited `dir` option cannot turn a remove button into
    an arbitrary-file delete.
    """
    resolved_roots = []
    for root in roots or []:
        if not root:
            continue
        try:
            resolved_roots.append(Path(root).expanduser().resolve())
        except OSError:
            continue

    deleted: list[str] = []
    missing: list[str] = []
    refused: list[dict] = []
    freed = 0

    for raw in candidates(paths):
        path = Path(raw)
        try:
            target = path.expanduser().resolve()
        except OSError as exc:
            refused.append({"path": raw, "reason": str(exc)})
            continue

        if resolved_roots and not any(
            target == root or root in target.parents for root in resolved_roots
        ):
            refused.append({"path": raw, "reason": "outside the download directory"})
            continue

        if not path.exists() and not path.is_symlink():
            missing.append(raw)
            continue

        if not _is_deletable(path):
            refused.append({"path": raw, "reason": "not a regular file"})
            continue

        try:
            size = path.stat().st_size if not path.is_symlink() else 0
        except OSError:
            size = 0
        try:
            path.unlink()
        except OSError as exc:
            refused.append({"path": raw, "reason": str(exc)})
            continue
        deleted.append(raw)
        freed += size

    prune_empty_dirs([p for p in paths if p], resolved_roots)

    return {
        "deleted": deleted,
        "missing": missing,
        "refused": refused,
        "bytes": freed,
    }


def prune_empty_dirs(paths: list[str], roots: list[Path]) -> None:
    """Drop the empty folders a multi-file torrent leaves behind.

    Walks up from each deleted file, stopping at the first non-empty directory
    and never removing a root itself.
    """
    if not roots:
        return
    for raw in paths:
        try:
            current = Path(raw).expanduser().resolve().parent
        except OSError:
            continue
        while True:
            if any(current == root for root in roots):
                break
            if not any(root in current.parents for root in roots):
                break
            try:
                next(current.iterdir())
                break  # not empty
            except StopIteration:
                pass
            except OSError:
                break
            try:
                current.rmdir()
            except OSError:
                break
            current = current.parent


# --------------------------------------------------------------------------
# a web page saved in place of a file
# --------------------------------------------------------------------------
#: Names under which a web page is the expected content.
PAGE_EXTENSIONS = {"html", "htm", "xhtml", "shtml", "php", "asp", "aspx", "jsp", "cgi",
                   "xml", "svg", "txt", "json"}


def expects_binary(path: str) -> bool:
    """Does this name promise something other than a web page?"""
    name = Path(path).name
    if "." not in name:
        return False  # no extension: nothing to hold the content to
    return name.rsplit(".", 1)[1].lower() not in PAGE_EXTENSIONS


def starts_like_html(path: str) -> bool | None:
    """True if the file begins as an HTML page, False if not, None if unknown yet.

    Unknown while its first bytes are not written: aria2 preallocates, and with
    several connections the start of the file may still be zeros.
    """
    try:
        with open(path, "rb") as handle:
            head = handle.read(1024)
    except OSError:
        return None
    if not head.strip(b"\0"):
        return None
    text = head.lstrip(b"\xef\xbb\xbf").lstrip().lower()
    # An XHTML page may open with an XML declaration before its <html>.
    return text.startswith((b"<!doctype html", b"<html")) or (
        text.startswith(b"<?xml") and b"<html" in text)
