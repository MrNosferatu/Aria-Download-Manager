"""File-hosting-site resolvers: page URL in, direct link out.

Add a site by writing a Resolver subclass and listing it in :func:`build_registry`.
XFileSharing clones need no code at all — add their domain to
``hosters.xfilesharing_domains`` in config.yaml.
"""

from __future__ import annotations

import re

import aiohttp

from .base import (
    DEFAULT_UA,
    Interaction,
    Resolved,
    ResolveError,
    Resolver,
    filename_from_disposition,
    host_of,
    safe_name,
)
from .mediafire import MediaFireResolver
from .xfilesharing import XFileSharingResolver

__all__ = [
    "DEFAULT_UA",
    "DirectResolver",
    "Interaction",
    "MediaFireResolver",
    "Resolved",
    "ResolveError",
    "Resolver",
    "XFileSharingResolver",
    "build_registry",
    "pick_resolver",
]


class DirectResolver(Resolver):
    """Fallback: the URL already points at a file, so just confirm and pass it on."""

    name = "direct"

    def matches(self, url: str) -> bool:
        return bool(re.match(r"^(https?|ftps?)://", url or ""))

    async def resolve(
        self, session: aiohttp.ClientSession, url: str, *, wait_cap: float = 120.0
    ) -> Resolved:
        filename = safe_name(url.split("?")[0].split("/")[-1])
        size = None
        try:
            async with session.head(
                url, headers={"User-Agent": DEFAULT_UA}, allow_redirects=True
            ) as head:
                if head.status < 400:
                    size = int(head.headers.get("Content-Length") or 0) or None
                    filename = (
                        safe_name(filename_from_disposition(head.headers.get("Content-Disposition", "")))
                        or filename
                    )
        except (aiohttp.ClientError, ValueError):
            pass
        return Resolved(url=url, filename=filename, size=size, note="treated as a direct link")


def build_registry(cfg=None) -> list[Resolver]:
    """Ordered resolvers; the first match wins, DirectResolver catches the rest."""
    resolvers: list[Resolver] = [
        MediaFireResolver(),
        XFileSharingResolver(),
        DirectResolver(),
    ]
    if cfg is None:
        return resolvers

    # hosters.resolver_domains: {resolver_name: [extra hosts]}
    extra: dict[str, list[str]] = {
        str(name): list(domains or [])
        for name, domains in (cfg.get("hosters.resolver_domains") or {}).items()
    }
    # Shorthand for the common case of adding an XFileSharing clone.
    if shorthand := list(cfg.get("hosters.xfilesharing_domains") or []):
        extra.setdefault("xfilesharing", []).extend(shorthand)

    for resolver in resolvers:
        if domains := extra.get(resolver.name):
            resolver.add_domains(domains)
    return resolvers


def pick_resolver(url: str, resolvers: list[Resolver]) -> Resolver | None:
    for resolver in resolvers:
        if resolver.matches(url):
            return resolver
    return None


def describe(resolvers: list[Resolver]) -> list[dict]:
    """Resolver summary for the UI."""
    return [
        {
            "name": resolver.name,
            "domains": list(resolver.domains),
            "interactive": resolver.interactive,
        }
        for resolver in resolvers
    ]
