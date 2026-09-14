"""Working out what a video stream actually offers, and in what qualities.

A modern player does not put a downloadable URL in the page. It fetches an HLS
or DASH manifest, then feeds segments to the ``<video>`` element through Media
Source Extensions, so ``video.src`` is a ``blob:`` handle to a buffer in memory
— useless to a download manager. What *is* still visible is the manifest going
past on the network, and a manifest is a published list of exactly the variants
a site is willing to serve.

That list is the quality picker. This module turns a manifest into it.

Nothing here fetches segments or muxes anything; it only reads manifests and
reports what they contain. HLS is RFC 8216, DASH is ISO/IEC 23009-1, and both
are parsed loosely on purpose — a manifest that a browser plays happily is not
always one that satisfies the specification.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from urllib.parse import urljoin, urlparse

#: Content types that mean "this response is a manifest", used by the extension's
#: request sniffer and again here when a URL alone is ambiguous.
HLS_TYPES = {
    "application/vnd.apple.mpegurl",
    "application/x-mpegurl",
    "audio/mpegurl",
    "audio/x-mpegurl",
}
DASH_TYPES = {"application/dash+xml"}

#: Progressive media: no manifest, the URL *is* the file.
DIRECT_TYPES = {
    "video/mp4",
    "video/webm",
    "video/x-matroska",
    "video/quicktime",
    "video/x-flv",
    "audio/mpeg",
    "audio/mp4",
    "audio/ogg",
    "audio/flac",
    "audio/wav",
}

DASH_NS = "{urn:mpeg:dash:schema:mpd:2011}"


@dataclass
class Variant:
    """One downloadable rendition of a stream."""

    #: Stable within a probe result; what the client sends back to download.
    id: str
    url: str
    #: hls | dash | direct
    kind: str
    width: int | None = None
    height: int | None = None
    #: bits per second, as the manifest declares it
    bandwidth: int | None = None
    codecs: str = ""
    frame_rate: float | None = None
    #: Set for DASH and for HLS audio renditions that download separately.
    audio_url: str = ""
    audio_codecs: str = ""
    #: True when the video track carries no audio and `audio_url` must be muxed in.
    needs_audio: bool = False
    language: str = ""
    label: str = ""

    def quality(self) -> str:
        """What the user picks from, in the words they think in."""
        if self.height:
            name = f"{self.height}p"
            if self.frame_rate and self.frame_rate >= 50:
                name += f"{round(self.frame_rate)}"
            return name
        if self.bandwidth:
            return f"{round(self.bandwidth / 1000)} kbps"
        return self.label or "source"

    def as_dict(self) -> dict:
        return {
            "id": self.id,
            "url": self.url,
            "kind": self.kind,
            "width": self.width,
            "height": self.height,
            "bandwidth": self.bandwidth,
            "codecs": self.codecs,
            "frameRate": self.frame_rate,
            "audioUrl": self.audio_url,
            "audioCodecs": self.audio_codecs,
            "needsAudio": self.needs_audio,
            "language": self.language,
            "label": self.label,
            "quality": self.quality(),
        }


@dataclass
class Probe:
    """Everything a probe learned about one media URL."""

    kind: str
    url: str
    variants: list[Variant] = field(default_factory=list)
    title: str = ""
    #: Set when the manifest is playable but nothing here can download it.
    unsupported: str = ""

    def as_dict(self) -> dict:
        return {
            "kind": self.kind,
            "url": self.url,
            "title": self.title,
            "unsupported": self.unsupported,
            "variants": [v.as_dict() for v in self.variants],
        }


# ---------------------------------------------------------------- detection
def kind_for(url: str, content_type: str = "") -> str:
    """hls | dash | direct | unknown, from the content type first, URL second.

    The content type is the honest signal; a URL is only a hint, and plenty of
    CDNs serve manifests from paths with no useful extension at all.
    """
    base = (content_type or "").split(";")[0].strip().lower()
    if base in HLS_TYPES:
        return "hls"
    if base in DASH_TYPES:
        return "dash"
    if base in DIRECT_TYPES:
        return "direct"

    path = urlparse(url).path.lower()
    if path.endswith(".m3u8") or path.endswith(".m3u"):
        return "hls"
    if path.endswith(".mpd"):
        return "dash"
    if any(path.endswith(ext) for ext in
           (".mp4", ".webm", ".mkv", ".mov", ".flv", ".m4v", ".m4a", ".mp3", ".ogg", ".flac", ".wav")):
        return "direct"
    return "unknown"


# --------------------------------------------------------------------- HLS
_ATTR = re.compile(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)')


def _attrs(line: str) -> dict[str, str]:
    """Parse an EXT-X tag's attribute list, honouring quoted commas."""
    _, _, rest = line.partition(":")
    out: dict[str, str] = {}
    for key, value in _ATTR.findall(rest):
        out[key] = value.strip('"')
    return out


def parse_hls(text: str, url: str) -> Probe:
    """Read an HLS playlist.

    A *master* playlist lists variant streams and is where quality choice comes
    from. A *media* playlist lists segments and is itself one quality — handed
    back as a single variant so the caller need not care which it got.
    """
    probe = Probe(kind="hls", url=url)
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if not lines or not lines[0].startswith("#EXTM3U"):
        probe.unsupported = "not an HLS playlist"
        return probe

    # Audio renditions live in their own tag and are referenced by group id.
    audio_groups: dict[str, list[dict]] = {}
    for line in lines:
        if not line.startswith("#EXT-X-MEDIA:"):
            continue
        attrs = _attrs(line)
        if attrs.get("TYPE") != "AUDIO" or not attrs.get("URI"):
            continue
        audio_groups.setdefault(attrs.get("GROUP-ID", ""), []).append({
            "url": urljoin(url, attrs["URI"]),
            "language": attrs.get("LANGUAGE", ""),
            "name": attrs.get("NAME", ""),
            "default": attrs.get("DEFAULT", "").upper() == "YES",
        })

    index = 0
    for i, line in enumerate(lines):
        if not line.startswith("#EXT-X-STREAM-INF:"):
            continue
        target = next((l for l in lines[i + 1:] if not l.startswith("#")), None)
        if not target:
            continue
        attrs = _attrs(line)
        width = height = None
        if resolution := attrs.get("RESOLUTION"):
            try:
                width, height = (int(part) for part in resolution.lower().split("x", 1))
            except ValueError:
                width = height = None
        frame_rate = None
        if raw_rate := attrs.get("FRAME-RATE"):
            try:
                frame_rate = float(raw_rate)
            except ValueError:
                frame_rate = None
        bandwidth = None
        for key in ("AVERAGE-BANDWIDTH", "BANDWIDTH"):
            if attrs.get(key):
                try:
                    bandwidth = int(attrs[key])
                    break
                except ValueError:
                    pass

        codecs = attrs.get("CODECS", "")
        group = audio_groups.get(attrs.get("AUDIO", ""), [])
        audio = next((a for a in group if a["default"]), group[0] if group else None)
        # A variant that names an audio group carries video only: its audio is a
        # separate rendition and has to be muxed back in after downloading.
        separate_audio = bool(attrs.get("AUDIO") and audio)

        index += 1
        probe.variants.append(Variant(
            id=f"hls-{index}",
            url=urljoin(url, target),
            kind="hls",
            width=width,
            height=height,
            bandwidth=bandwidth,
            codecs=codecs,
            frame_rate=frame_rate,
            audio_url=audio["url"] if separate_audio else "",
            needs_audio=separate_audio,
            language=(audio or {}).get("language", ""),
            label=attrs.get("NAME", ""),
        ))

    if not probe.variants:
        # A media playlist: segments, not variants. One quality, this URL.
        if any(ln.startswith("#EXTINF") for ln in lines):
            probe.variants.append(Variant(id="hls-1", url=url, kind="hls", label="source"))
        else:
            probe.unsupported = "playlist lists no streams or segments"
    probe.variants.sort(key=_rank, reverse=True)
    return probe


# -------------------------------------------------------------------- DASH
def parse_dash(text: str, url: str) -> Probe:
    """Read a DASH MPD.

    DASH almost always separates video and audio into different adaptation
    sets, so a chosen video Representation is paired with the best audio one
    and marked for muxing.
    """
    probe = Probe(kind="dash", url=url)
    try:
        root = ET.fromstring(text)
    except ET.ParseError as exc:
        probe.unsupported = f"unreadable MPD: {exc}"
        return probe

    def tag(name: str) -> str:
        return f"{DASH_NS}{name}"

    if root.get("type") == "dynamic":
        probe.unsupported = "live stream"

    base = url
    if (base_el := root.find(tag("BaseURL"))) is not None and (base_el.text or "").strip():
        base = urljoin(url, base_el.text.strip())

    videos: list[Variant] = []
    audios: list[Variant] = []
    index = 0
    for adaptation in root.iter(tag("AdaptationSet")):
        kind = (adaptation.get("contentType")
                or (adaptation.get("mimeType") or "").split("/")[0])
        language = adaptation.get("lang", "")
        for rep in adaptation.findall(tag("Representation")):
            mime = rep.get("mimeType") or adaptation.get("mimeType") or ""
            if not kind:
                kind = mime.split("/")[0]
            rep_base = base
            if (rb := rep.find(tag("BaseURL"))) is not None and (rb.text or "").strip():
                rep_base = urljoin(base, rb.text.strip())
            try:
                bandwidth = int(rep.get("bandwidth") or 0) or None
            except ValueError:
                bandwidth = None
            index += 1
            variant = Variant(
                id=f"dash-{index}",
                url=rep_base,
                kind="dash",
                bandwidth=bandwidth,
                codecs=rep.get("codecs") or adaptation.get("codecs") or "",
                language=language,
            )
            for attr, field_name in (("width", "width"), ("height", "height")):
                raw = rep.get(attr) or adaptation.get(attr)
                if raw:
                    try:
                        setattr(variant, field_name, int(raw))
                    except ValueError:
                        pass
            if raw_rate := (rep.get("frameRate") or adaptation.get("frameRate")):
                variant.frame_rate = _ratio(raw_rate)
            (videos if kind == "video" else audios).append(variant)

    best_audio = max(audios, key=lambda v: v.bandwidth or 0, default=None)
    for variant in videos:
        if best_audio:
            variant.audio_url = best_audio.url
            variant.audio_codecs = best_audio.codecs
            variant.needs_audio = True
    probe.variants = videos or audios
    if not probe.variants and not probe.unsupported:
        probe.unsupported = "MPD lists no representations"
    probe.variants.sort(key=_rank, reverse=True)
    return probe


def _ratio(value: str) -> float | None:
    """DASH frame rates may be written as "30" or as "30000/1001"."""
    try:
        if "/" in value:
            num, _, den = value.partition("/")
            return float(num) / float(den or 1)
        return float(value)
    except (ValueError, ZeroDivisionError):
        return None


def _rank(variant: Variant) -> tuple:
    return (variant.height or 0, variant.bandwidth or 0)


# ------------------------------------------------------------------ direct
def parse_direct(url: str, content_type: str = "", size: int | None = None) -> Probe:
    """A progressive file: one variant, and the URL is it."""
    probe = Probe(kind="direct", url=url)
    probe.variants.append(Variant(
        id="direct-1", url=url, kind="direct", label="source",
        bandwidth=None, codecs=content_type or "",
    ))
    return probe


def parse(text: str, url: str, content_type: str = "") -> Probe:
    """Dispatch on what the response turned out to be."""
    kind = kind_for(url, content_type)
    if kind == "hls":
        return parse_hls(text, url)
    if kind == "dash":
        return parse_dash(text, url)
    if kind == "direct":
        return parse_direct(url, content_type)
    # Content type lied or was missing: sniff the body.
    head = text.lstrip()[:512]
    if head.startswith("#EXTM3U"):
        return parse_hls(text, url)
    if "<MPD" in head or "urn:mpeg:dash" in head:
        return parse_dash(text, url)
    return Probe(kind="unknown", url=url, unsupported="not a recognised manifest")


def suggested_name(url: str, title: str = "", height: int | None = None) -> str:
    """A filename a person would have chosen."""
    stem = re.sub(r"[\\/:*?\"<>|]+", "_", (title or "").strip())
    if not stem:
        path = urlparse(url).path
        stem = re.sub(r"\.(m3u8|mpd)$", "", path.rsplit("/", 1)[-1]) or "video"
    stem = stem[:120].strip(" ._-") or "video"
    if height:
        stem += f"_{height}p"
    return f"{stem}.mp4"
