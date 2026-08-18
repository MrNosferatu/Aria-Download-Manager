"""Resolver contract shared by all file-hosting-site handlers.

A resolver turns a *page* URL (what you copy from the browser) into a *direct*
URL that aria2 can fetch. Resolution has three possible outcomes:

  Resolved      — we have a direct link; hand it to aria2 now.
  Interaction   — a human has to do something (solve a captcha) before a link
                  exists. The job parks until an answer arrives.
  ResolveError  — this link is dead, private, or the page changed shape.

Direct links from most hosts are short-lived and sometimes bound to the session
that generated them, so a resolver is always run immediately before the download
starts, never in advance.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

import aiohttp

DEFAULT_UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


class ResolveError(Exception):
    """The page cannot yield a download link (dead file, private, changed HTML)."""

    def __init__(self, message: str, *, permanent: bool = False):
        super().__init__(message)
        self.permanent = permanent


@dataclass
class Resolved:
    """A direct link ready for aria2."""

    url: str
    filename: str | None = None
    size: int | None = None
    referer: str | None = None
    cookies: dict[str, str] = field(default_factory=dict)
    headers: dict[str, str] = field(default_factory=dict)
    note: str = ""

    def aria2_options(self, user_agent: str = DEFAULT_UA) -> dict[str, Any]:
        """Translate into aria2 per-download options."""
        options: dict[str, Any] = {"user-agent": user_agent}
        if self.referer:
            options["referer"] = self.referer
        if self.filename:
            options["out"] = self.filename
        extra = [f"{k}: {v}" for k, v in self.headers.items() if k and v]
        if self.cookies:
            jar = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
            extra.append(f"Cookie: {jar}")
        if extra:
            options["header"] = extra
        return options


@dataclass
class Interaction:
    """A human step is required before a link can be produced.

    kind:
      "captcha_code"  — a code is readable from an image; the UI collects it and
                        the resolver finishes the flow server-side.
      "browser"       — the challenge cannot be answered outside a real browser
                        (reCAPTCHA/hCaptcha/Turnstile). The user opens the page,
                        completes it there, and the resolved link is sent back —
                        by the userscript automatically, or pasted by hand.
    """

    kind: str
    message: str
    page_url: str
    image_url: str | None = None
    wait_seconds: float = 0.0
    # Opaque per-resolver state needed to finish the flow (form fields, cookies).
    state: dict[str, Any] = field(default_factory=dict)


class Resolver:
    """Base class. Subclasses declare `name` and `domains`."""

    name = "base"
    domains: tuple[str, ...] = ()
    #: Set when the host needs a browser-solved challenge in the common case.
    interactive = False

    def matches(self, url: str) -> bool:
        host = host_of(url)
        return any(host == d or host.endswith("." + d) for d in self.domains)

    def add_domains(self, domains: list[str] | tuple[str, ...]) -> None:
        """Extend this resolver's host list (clones, mirrors, private instances)."""
        cleaned = tuple(
            str(domain).strip().lower().removeprefix("www.")
            for domain in domains
            if str(domain).strip()
        )
        self.domains = tuple(dict.fromkeys(tuple(self.domains) + cleaned))

    async def resolve(
        self, session: aiohttp.ClientSession, url: str, *, wait_cap: float = 120.0
    ) -> Resolved | Interaction:
        raise NotImplementedError

    async def answer(
        self,
        session: aiohttp.ClientSession,
        interaction: Interaction,
        reply: dict[str, Any],
        *,
        wait_cap: float = 120.0,
    ) -> Resolved | Interaction:
        """Continue a parked flow with a human answer."""
        raise ResolveError(f"{self.name} cannot continue from an interaction")


# ---------------------------------------------------------------- helpers
def host_of(url: str) -> str:
    match = re.match(r"^[a-zA-Z][\w+.-]*://([^/@]*@)?([^/:?#]+)", url or "")
    return (match.group(2) if match else "").lower().removeprefix("www.")


def unescape_attr(value: str) -> str:
    """Minimal HTML entity decode for values pulled out of attributes."""
    for entity, char in (
        ("&amp;", "&"), ("&quot;", '"'), ("&#39;", "'"),
        ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
    ):
        value = value.replace(entity, char)
    return value.strip()


def hidden_inputs(html: str, form_html: str | None = None) -> dict[str, str]:
    """Collect name/value pairs from the inputs of a form."""
    scope = form_html if form_html is not None else html
    fields: dict[str, str] = {}
    for tag in re.findall(r"<input\b[^>]*>", scope, re.I):
        name = re.search(r'\bname\s*=\s*["\']([^"\']+)["\']', tag, re.I)
        if not name:
            continue
        kind = re.search(r'\btype\s*=\s*["\']([^"\']+)["\']', tag, re.I)
        if kind and kind.group(1).lower() in ("submit", "button", "reset", "image"):
            continue
        value = re.search(r'\bvalue\s*=\s*["\']([^"\']*)["\']', tag, re.I)
        fields[unescape_attr(name.group(1))] = unescape_attr(value.group(1)) if value else ""
    return fields


def find_form(html: str, needle: str) -> str | None:
    """Return the <form> block containing `needle`, if any."""
    for block in re.findall(r"<form\b.*?</form>", html, re.I | re.S):
        if needle in block:
            return block
    return None


#: Markers of a Cloudflare challenge/interstitial served *instead of* the page.
#:
#: Deliberately NOT included: "challenge-platform". Every Cloudflare-fronted site
#: loads /cdn-cgi/challenge-platform/…/main.js as an ordinary telemetry beacon, so
#: matching it flags perfectly good pages as challenges (kenfiles.com does this).
CLOUDFLARE_MARKERS = (
    "just a moment",
    "cf-browser-verification",
    "cf_chl_opt",
    "attention required! | cloudflare",
    "checking if the site connection is secure",
    "enable javascript and cookies to continue",
    'id="challenge-form"',
    "cf-im-under-attack",
)


def detect_cloudflare(html: str, status: int = 200, headers=None) -> str | None:
    """Return a reason if Cloudflare is challenging us rather than serving the page.

    A challenge cannot be answered outside a real browser: the clearance token is
    minted by Cloudflare's own JavaScript. The way through is the user's browser —
    either it hands back the finished link, or it shares its ``cf_clearance``
    cookie so the manager can reuse the same clearance.
    """
    headers = headers or {}
    if headers.get("cf-mitigated") == "challenge":
        return "Cloudflare challenge (cf-mitigated header)"
    # Scan the whole body: markers are not always near the top.
    lowered = (html or "").lower()
    hit = next((marker for marker in CLOUDFLARE_MARKERS if marker in lowered), None)
    if hit:
        return f"Cloudflare challenge page ({hit!r})"
    if status in (403, 503) and "cloudflare" in lowered:
        return f"Cloudflare blocked the request (HTTP {status})"
    return None


def filename_from_disposition(value: str) -> str | None:
    if not value:
        return None
    match = re.search(r"filename\*?=(?:UTF-8'')?\"?([^\";]+)\"?", value, re.I)
    return unescape_attr(match.group(1)) if match else None


def safe_name(name: str | None) -> str | None:
    """Reduce to a bare filename so it can never escape the download dir."""
    if not name:
        return None
    name = unescape_attr(name).replace("\\", "/").split("/")[-1].strip()
    name = re.sub(r'[\x00-\x1f<>:"|?*]', "_", name)
    return name or None
