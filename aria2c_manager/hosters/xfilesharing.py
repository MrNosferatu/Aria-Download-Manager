"""XFileSharing-style resolver — covers kenfiles and the many clones of that script.

The flow these sites use:

  1. GET the file page. It holds a form with ``op=download1`` plus hidden fields
     (id, fname, referer, method_free).
  2. POST that form. The reply is the "wait" page: a countdown (typically 30 s), a
     second form with ``op=download2``, and usually a challenge.
  3. Wait out the countdown, POST ``op=download2`` (with the challenge answer if
     there is one). The reply carries the direct link, or 302s to it.

Challenge handling:

  * No challenge → fully automatic.
  * The classic XFileSharing "ordered digits" challenge, where the digits are
    plain text in the HTML positioned with CSS, is read directly from the markup.
  * An **image** captcha is shown to you in the web UI and you type the code.
  * reCAPTCHA / hCaptcha / Turnstile cannot be answered outside a real browser
    and are never attempted here — the job parks, you open the page, complete it
    there, and the resulting link is sent back (the userscript does this
    automatically, or you paste it).
"""

from __future__ import annotations

import asyncio
import re
from urllib.parse import urljoin

import aiohttp

from .base import (
    Interaction,
    Resolved,
    ResolveError,
    Resolver,
    detect_cloudflare,
    find_form,
    hidden_inputs,
    host_of,
    safe_name,
    unescape_attr,
)

DEAD_MARKERS = (
    "file not found",
    "file was deleted",
    "file has been removed",
    "no such file",
    "file is not available",
    "reached the download limit",
)
# Ordered most-specific first: the label drives the wording the user sees.
BROWSER_CHALLENGES = (
    ("cf-turnstile", "Cloudflare Turnstile"),
    ("challenges.cloudflare.com", "Cloudflare Turnstile"),
    ("turnstile.response", "Cloudflare Turnstile"),
    ("h-captcha", "hCaptcha"),
    ("hcaptcha.com", "hCaptcha"),
    ("g-recaptcha", "reCAPTCHA"),
    ("recaptcha/api.js", "reCAPTCHA"),
    ("data-sitekey", "reCAPTCHA/hCaptcha"),
)

#: Extensions that mean "this is a page or an asset", never the download itself.
NOT_A_FILE_RE = re.compile(
    r"\.(?:html?|php\d?|aspx?|jspx?|cgi|do|action|css|js|json|xml|png|jpe?g|gif|svg"
    r"|webp|ico|woff2?|ttf|eot)(?:[?#]|$)",
    re.I,
)
#: Extensions that clearly ARE a download.
IS_A_FILE_RE = re.compile(
    r"\.(?:zip|rar|r\d\d|7z|tar|t?gz|bz2|txz|xz|zst|iso|img|bin|exe|msi|apk|dmg|pkg"
    r"|deb|rpm|appimage|mp3|mp4|m4[av]|flac|wav|ogg|opus|aac|mkv|avi|mov|webm|wmv|flv"
    r"|pdf|epub|mobi|docx?|xlsx?|pptx?|srt|sub|part\d+\.rar)(?:[?#]|$)",
    re.I,
)

#: Turnstile is usually one click (often zero), so say so rather than sounding dire.
CHALLENGE_HINTS = {
    "Cloudflare Turnstile": (
        "Cloudflare Turnstile — usually just a checkbox. Open the page: with the "
        "userscript installed the wait, the tick-through and the link hand-back are "
        "automatic, so you only click the box (sometimes not even that)."
    ),
}


class XFileSharingResolver(Resolver):
    name = "xfilesharing"
    domains = ("kenfiles.com",)
    interactive = True

    def __init__(self, extra_domains: tuple[str, ...] = ()):
        if extra_domains:
            self.domains = tuple(self.domains) + tuple(extra_domains)

    # ---- step 1 + 2 ------------------------------------------------------
    async def resolve(
        self, session: aiohttp.ClientSession, url: str, *, wait_cap: float = 120.0
    ) -> Resolved | Interaction:
        fname: str | None = None
        async with session.get(url) as res:
            if res.status == 404:
                raise ResolveError("Host returned 404 for this file", permanent=True)
            html = await res.text(errors="replace")
            page_url = str(res.url)
            status, headers = res.status, res.headers
            if status >= 400:
                blocked = detect_cloudflare(html, status, headers)
                if not blocked:
                    res.raise_for_status()

        form = find_form(html, "download1") or find_form(html, 'name="op"')
        if not form:
            # No form: now the heuristics are worth consulting.
            if blocked := detect_cloudflare(html, status, headers):
                return self._cloudflare_interaction(page_url, blocked)
            self._guard(html)

        if form:
            fields = hidden_inputs(html, form)
            fields.setdefault("op", "download1")
            fields.setdefault("referer", page_url)
            # The free-download button is a submit input on most clones.
            free = re.search(r'name=["\']method_free["\'][^>]*value=["\']([^"\']*)["\']', form, re.I)
            fields["method_free"] = free.group(1) if free else "Free Download"
            # The host tells us the real filename here; the URL often does not.
            fname = safe_name(fields.get("fname")) or fname
            async with session.post(
                page_url, data=fields, headers={"Referer": page_url}
            ) as res:
                html = await res.text(errors="replace")
                page_url = str(res.url)
                status, headers = res.status, res.headers
                if status >= 400:
                    blocked = detect_cloudflare(html, status, headers)
                    if not blocked:
                        res.raise_for_status()
            # Only judge the reply if it carries neither a next step nor a link.
            if not (find_form(html, "download2") or find_form(html, 'name="op"')
                    or self._extract_direct(html, page_url)):
                if blocked := detect_cloudflare(html, status, headers):
                    return self._cloudflare_interaction(page_url, blocked)
                self._guard(html)

        return await self._from_wait_page(
            session, html, page_url, wait_cap=wait_cap, fname=fname
        )

    # ---- step 3 ----------------------------------------------------------
    async def _from_wait_page(
        self,
        session: aiohttp.ClientSession,
        html: str,
        page_url: str,
        *,
        wait_cap: float,
        answer: str | None = None,
        fname: str | None = None,
    ) -> Resolved | Interaction:
        # Maybe the link is already here (some clones skip the second step).
        if direct := self._extract_direct(html, page_url):
            return self._resolved(direct, page_url, fname)

        form = find_form(html, "download2") or find_form(html, 'name="op"')
        if not form:
            self._guard(html)  # may raise with the host's real reason
            raise ResolveError(
                "No download form on the wait page — the site layout may have changed"
            )
        fields = hidden_inputs(html, form)
        fields.setdefault("op", "download2")
        fields.setdefault("referer", page_url)
        fields.setdefault("down_script", "1")
        fields.pop("method_premium", None)

        countdown = self._countdown(html)
        challenge = self._challenge(html, page_url)

        if answer is None and challenge:
            if challenge["kind"] == "browser":
                hint = CHALLENGE_HINTS.get(challenge["label"]) or (
                    f"{challenge['label']} must be completed in a browser. Open the page, "
                    "complete the challenge and start the download — the link is captured "
                    "automatically, or paste it here."
                )
                return Interaction(
                    kind="browser",
                    message=hint,
                    page_url=page_url,
                    wait_seconds=countdown,
                    state=self._state(session, fields, page_url, countdown, fname),
                )
            if challenge["kind"] == "code":
                return Interaction(
                    kind="captcha_code",
                    message=f"Type the {challenge['label']} shown on the page.",
                    page_url=page_url,
                    image_url=challenge.get("image"),
                    wait_seconds=countdown,
                    state=self._state(session, fields, page_url, countdown, fname),
                )
            # "digits" — plain text in the markup, read straight off the page.
            fields["code"] = challenge["code"]
        elif answer is not None:
            fields["code"] = answer

        if countdown > wait_cap:
            raise ResolveError(
                f"Host wants a {countdown:.0f}s wait, over the {wait_cap:.0f}s cap "
                "(raise hosters.wait_cap_seconds to allow it)"
            )
        if countdown > 0:
            await asyncio.sleep(countdown + 1.0)  # a second of slack

        return await self._submit(session, fields, page_url, fname)

    async def _submit(
        self, session: aiohttp.ClientSession, fields: dict, page_url: str,
        fname: str | None = None,
    ) -> Resolved:
        async with session.post(
            page_url, data=fields, headers={"Referer": page_url}, allow_redirects=False
        ) as res:
            if res.status in (301, 302, 303, 307, 308):
                location = res.headers.get("Location", "")
                if location:
                    return self._resolved(urljoin(page_url, location), page_url, fname)
            body = await res.text(errors="replace")

        # A link in the reply is success, whatever else the page happens to say.
        direct = self._extract_direct(body, page_url)
        if not direct:
            if error := self._error_text(body):
                raise ResolveError(f"Host refused: {error}")
            self._guard(body)
            raise ResolveError(
                "No download link in the final response — the countdown may have been "
                "missed or the challenge answer was wrong"
            )
        return self._resolved(direct, page_url, fname)

    async def answer(
        self,
        session: aiohttp.ClientSession,
        interaction: Interaction,
        reply: dict,
        *,
        wait_cap: float = 120.0,
    ) -> Resolved | Interaction:
        if direct := (reply.get("direct_url") or "").strip():
            return self._resolved(
                direct, interaction.page_url, (interaction.state or {}).get("fname")
            )

        code = str(reply.get("code") or "").strip()
        if not code:
            raise ResolveError("No captcha code or direct link supplied")

        state = interaction.state or {}
        for name, value in (state.get("cookies") or {}).items():
            session.cookie_jar.update_cookies({name: value})
        fields = dict(state.get("fields") or {})
        if not fields:
            raise ResolveError("Lost the form state for this job — retry it from the start")
        fields["code"] = code

        remaining = float(state.get("countdown") or 0)
        if remaining > 0:
            elapsed = float(state.get("elapsed_since", 0) or 0)
            if remaining - elapsed > 0:
                await asyncio.sleep(min(remaining - elapsed, wait_cap) + 1.0)
        return await self._submit(
            session, fields, state.get("page_url") or interaction.page_url,
            state.get("fname"),
        )

    # ---- parsing ---------------------------------------------------------
    @staticmethod
    def _messages(html: str) -> list[str]:
        """Text from the places a real user-facing message actually appears.

        Whole-page substring matching is useless on these sites: a normal kenfiles
        file page carries the literal text "file not found" inside a JavaScript
        template, which used to abort every job.
        """
        scopes: list[str] = []
        if title := re.search(r"<title>(.*?)</title>", html, re.I | re.S):
            scopes.append(title.group(1))
        scopes += re.findall(
            r'<(?:div|p|span|h[1-4]|td)[^>]*class=["\'][^"\']*'
            r'(?:err|alert|warning|notfound|not-found|msg)[^"\']*["\'][^>]*>(.*?)'
            r"</(?:div|p|span|h[1-4]|td)>",
            html, re.I | re.S,
        )
        scopes += re.findall(r"<h[12][^>]*>(.*?)</h[12]>", html, re.I | re.S)
        return [
            re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", scope)).strip().lower()
            for scope in scopes
        ]

    @classmethod
    def _guard(cls, html: str) -> None:
        """Raise only when a message element genuinely says the file is gone.

        Called on failure paths only — if the page yielded a usable form or link,
        the content is proof enough that the file exists.
        """
        for text in cls._messages(html):
            for marker in DEAD_MARKERS:
                if marker in text:
                    raise ResolveError(
                        f"Host says: {marker}",
                        permanent="deleted" in marker or "not found" in marker,
                    )
            wait = re.search(
                r"you\s+(?:have\s+to|must)\s+wait\s+([\dhms\s]+?)\s*(?:till|before|until|to)",
                text,
            )
            if wait:
                raise ResolveError(f"Host enforces a cooldown: wait {wait.group(1).strip()}")

    @staticmethod
    def _error_text(html: str) -> str | None:
        for pattern in (
            r'<div[^>]*class=["\'][^"\']*err[^"\']*["\'][^>]*>(.*?)</div>',
            r'<p[^>]*class=["\'][^"\']*err[^"\']*["\'][^>]*>(.*?)</p>',
        ):
            match = re.search(pattern, html, re.I | re.S)
            if match:
                text = re.sub(r"<[^>]+>", " ", match.group(1))
                text = unescape_attr(re.sub(r"\s+", " ", text))
                if text:
                    return text[:200]
        if "skipped countdown" in html.lower():
            return "skipped countdown"
        return None

    @staticmethod
    def _countdown(html: str) -> float:
        """Seconds the host wants us to wait before submitting step 2.

        Patterns are ordered most-specific first. Real kenfiles markup is
        ``<span id="countdowns">Wait <span class="seconds fw-bold …">30</span>
        seconds</span>`` — so the class is multi-valued and the id is plural,
        which naive anchors miss.
        """
        patterns = (
            r'class=["\'][^"\']*\bseconds\b[^"\']*["\'][^>]*>\s*(\d+)',
            r'id=["\']countdowns?["\'][^>]*>(?:[^<]*<[^>]*>)?\s*(\d+)',
            r'id=["\']countdown[^"\']*["\'][^>]*>\s*(\d+)',
            r"var\s+(?:secs|seconds|countdown)\s*=\s*(\d+)",
            r"wait\s*(?:<[^>]+>\s*)?(\d{1,3})\s*(?:</[^>]+>\s*)?seconds",
        )
        for pattern in patterns:
            match = re.search(pattern, html, re.I | re.S)
            if not match:
                continue
            try:
                seconds = float(match.group(1))
            except ValueError:
                continue
            if 0 <= seconds <= 3600:      # ignore nonsense from unrelated markup
                return seconds
        return 0.0

    @classmethod
    def _challenge(cls, html: str, page_url: str) -> dict | None:
        lowered = html.lower()
        for needle, label in BROWSER_CHALLENGES:
            if needle in lowered:
                return {"kind": "browser", "label": label}

        # The classic XFileSharing challenge: digits sit in the HTML as text,
        # ordered by a CSS offset. Reading them is plain parsing, not solving.
        digits = re.findall(
            r"padding-left\s*:\s*(\d+)px[^>]*>\s*(?:&#\d+;|(\d))\s*<", html, re.I
        )
        if len(digits) >= 3:
            ordered = sorted(
                ((int(offset), digit) for offset, digit in digits if digit),
                key=lambda pair: pair[0],
            )
            code = "".join(digit for _, digit in ordered)
            if code.isdigit() and len(code) >= 3:
                return {"kind": "digits", "code": code, "label": "ordered digits"}

        image = re.search(
            r'<img[^>]+src=["\']([^"\']*(?:captcha|ccaptcha|kcaptcha)[^"\']*)["\']', html, re.I
        )
        if image and re.search(r'name=["\']code["\']', html, re.I):
            return {
                "kind": "code",
                "label": "captcha code",
                "image": urljoin(page_url, unescape_attr(image.group(1))),
            }
        if re.search(r'name=["\']code["\']', html, re.I):
            return {"kind": "code", "label": "code shown on the page", "image": None}
        return None

    @staticmethod
    def _plausible(candidate: str, page_url: str, *, strict: bool) -> bool:
        """Reject the page's own URL, pages and assets posing as downloads.

        Without this, a canonical <link> or og:url on the file page itself matches
        and aria2 cheerfully downloads the HTML page as the "file".
        """
        if not candidate or not candidate.lower().startswith(("http://", "https://")):
            return False
        strip = lambda url: url.split("#")[0].split("?")[0].rstrip("/").lower()  # noqa: E731
        if strip(candidate) == strip(page_url):
            return False
        if NOT_A_FILE_RE.search(candidate):
            return False
        if strict:
            # A bare regex sweep of the page needs more evidence: either the link
            # lives on a different host (dl1.example.com) or it names a real file.
            if host_of(candidate) == host_of(page_url) and not IS_A_FILE_RE.search(candidate):
                return False
        return True

    @classmethod
    def _extract_direct(cls, html: str, page_url: str) -> str | None:
        base_host = host_of(page_url)
        for tag in re.findall(r"<a\b[^>]*>", html, re.I | re.S):
            if re.search(r'id=["\'](?:direct_link|dllink|download_link)["\']', tag, re.I) or \
               re.search(r'class=["\'][^"\']*(?:btn-dow|link-dl|dlbutton|dl_link|download-link)[^"\']*["\']', tag, re.I):
                href = re.search(r'href\s*=\s*["\']([^"\']+)["\']', tag, re.I)
                if href:
                    candidate = unescape_attr(href.group(1))
                    if cls._plausible(candidate, page_url, strict=False):
                        return candidate

        redirect = re.search(
            r'(?:window\.)?location(?:\.href)?\s*=\s*["\'](https?://[^"\']+)["\']', html, re.I
        )
        if redirect:
            candidate = unescape_attr(redirect.group(1))
            if cls._plausible(candidate, page_url, strict=False):
                return candidate

        # A link on a sibling host (dl1.example.com) pointing at a real filename.
        if re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", base_host):
            root = base_host  # an IP has no registrable suffix to trim to
        else:
            root = ".".join(base_host.split(".")[-2:]) if base_host else ""
        if root:
            pattern = re.compile(
                r'https?://[\w.-]*' + re.escape(root)
                + r'(?::\d+)?/[^\s"\'<>]+\.[A-Za-z0-9]{2,5}(?:\?[^\s"\'<>]*)?',
                re.I,
            )
            for raw in pattern.findall(html):
                candidate = unescape_attr(raw)
                if cls._plausible(candidate, page_url, strict=True):
                    return candidate
        return None

    def _state(
        self, session: aiohttp.ClientSession, fields: dict, page_url: str,
        countdown: float, fname: str | None = None,
    ) -> dict:
        cookies: dict[str, str] = {}
        try:
            for cookie in session.cookie_jar:
                cookies[cookie.key] = cookie.value
        except Exception:
            pass
        return {
            "resolver": self.name,
            "fields": fields,
            "page_url": page_url,
            "countdown": countdown,
            "cookies": cookies,
            "fname": fname,
        }

    def _cloudflare_interaction(self, page_url: str, reason: str) -> Interaction:
        return Interaction(
            kind="browser",
            message=(
                f"{reason}. Cloudflare will not clear a request that is not a real "
                "browser, so open the page once: the userscript can then share this "
                "site's clearance cookie, or hand back the finished link."
            ),
            page_url=page_url,
            state={"resolver": self.name, "cloudflare": True},
        )

    def _resolved(self, direct: str, page_url: str, fname: str | None = None) -> Resolved:
        return Resolved(
            url=direct,
            filename=fname or safe_name(direct.split("?")[0].split("/")[-1]),
            referer=page_url,
            note=f"{self.name} flow",
        )
