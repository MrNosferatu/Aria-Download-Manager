"""MediaFire resolver.

MediaFire needs no waiting and no captcha for public files: the file page carries
the direct link in its download button. Verified page shape (August 2026):

    <a class="input popsok" aria-label="Download file"
       href="https://download1514.mediafire.com/<token>/<key>/<name>"
       id="downloadButton" rel="nofollow">

The token is regenerated on every page load and expires, so the link is fetched
immediately before the download starts, never cached.
"""

from __future__ import annotations

import base64
import binascii
import re

import aiohttp

from .base import (
    DEFAULT_UA,
    Interaction,
    detect_cloudflare,
    Resolved,
    ResolveError,
    Resolver,
    filename_from_disposition,
    safe_name,
    unescape_attr,
)

DIRECT_RE = re.compile(r"https://download\d+\.mediafire\.com/[^\s\"'<>\\]+", re.I)
DEAD_MARKERS = (
    "invalid or deleted file",
    "file has been removed",
    "the key you provided for file download was invalid",
    "this file has been deleted",
    "removed for violation",
)


class MediaFireResolver(Resolver):
    name = "mediafire"
    domains = ("mediafire.com",)

    async def resolve(
        self, session: aiohttp.ClientSession, url: str, *, wait_cap: float = 120.0
    ) -> Resolved | Interaction:
        if "/folder/" in url:
            raise ResolveError(
                "MediaFire folder links are not supported — open the folder and "
                "queue the individual files.",
                permanent=True,
            )

        async with session.get(url) as res:
            if res.status == 404:
                raise ResolveError("MediaFire says this file does not exist (404)", permanent=True)
            html = await res.text(errors="replace")
            final_url = str(res.url)
            blocked = detect_cloudflare(html, res.status, res.headers)
            if not blocked:
                res.raise_for_status()

        if blocked:
            return Interaction(
                kind="browser",
                message=(
                    f"{blocked}. Open the page once so the userscript can share this "
                    "site's clearance cookie, or hand back the finished link."
                ),
                page_url=final_url,
                state={"resolver": self.name, "cloudflare": True},
            )

        lowered = html.lower()
        for marker in DEAD_MARKERS:
            if marker in lowered:
                raise ResolveError(f"MediaFire: {marker}", permanent=True)

        direct = self._extract(html)
        if not direct:
            # MediaFire occasionally serves a JS-only interstitial. Rather than
            # fail the job, let the user finish it in a browser.
            return Interaction(
                kind="browser",
                message=(
                    "Could not find the download link in MediaFire's HTML — the page "
                    "layout may have changed, or it is showing an interstitial. Open "
                    "the page, start the download, and the link will be captured."
                ),
                page_url=final_url,
                state={"resolver": self.name},
            )

        filename = self._filename(html) or safe_name(direct.split("?")[0].split("/")[-1])
        size = None
        try:
            async with session.head(
                direct, headers={"Referer": final_url}, allow_redirects=True,
            ) as head:
                if head.status < 400:
                    size = int(head.headers.get("Content-Length") or 0) or None
                    filename = (
                        safe_name(filename_from_disposition(head.headers.get("Content-Disposition", "")))
                        or filename
                    )
        except (aiohttp.ClientError, ValueError):
            pass  # HEAD is a nicety; the link is still usable

        return Resolved(
            url=direct,
            filename=filename,
            size=size,
            referer=final_url,
            note="direct link from download button",
        )

    # ---- parsing ---------------------------------------------------------
    @staticmethod
    def _extract(html: str) -> str | None:
        # 1. The download button, matched without assuming attribute order.
        for tag in re.findall(r"<a\b[^>]*>", html, re.I | re.S):
            if 'id="downloadButton"' in tag or "id='downloadButton'" in tag:
                href = re.search(r'href\s*=\s*["\']([^"\']+)["\']', tag, re.I | re.S)
                if href and href.group(1).startswith("http"):
                    return unescape_attr(href.group(1))

        # 2. Any MediaFire download host URL anywhere on the page.
        match = DIRECT_RE.search(html)
        if match:
            return unescape_attr(match.group(0))

        # 3. The scrambled variant MediaFire has used on and off.
        scrambled = re.search(
            r'data-scrambled-url\s*=\s*["\']([A-Za-z0-9+/=]+)["\']', html, re.I
        )
        if scrambled:
            try:
                decoded = base64.b64decode(scrambled.group(1)).decode("utf-8", "replace")
            except (binascii.Error, ValueError):
                decoded = ""
            if decoded.startswith("http"):
                return decoded.strip()
        return None

    @staticmethod
    def _filename(html: str) -> str | None:
        for pattern in (
            r'<div class="filename">([^<]+)</div>',
            r'"fileName"\s*:\s*"([^"]+)"',
            r'<div class="dl-info">.*?<div class="filename">([^<]+)',
        ):
            match = re.search(pattern, html, re.I | re.S)
            if match:
                return safe_name(match.group(1))
        return None
