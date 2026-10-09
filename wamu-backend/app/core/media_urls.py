"""Rewrite stored media paths so phones can fetch them over the live tunnel/LAN."""

from __future__ import annotations

from typing import Any
from urllib.parse import urlsplit, urlunsplit

from fastapi import Request

_TUNNEL_SUFFIXES = (".trycloudflare.com", ".loca.lt", ".lhr.life")


def public_origin(request: Request) -> str:
    """Prefer HTTPS for public tunnels (Cloudflare / localhost.run).

    cloudflared often forwards with Host=127.0.0.1:8000 and puts the public
    hostname in X-Forwarded-Host — prefer that so media URLs stay reachable
    on phones.
    """
    forwarded_host = (request.headers.get("x-forwarded-host") or "").split(",")[0].strip()
    raw_host = (request.headers.get("host") or "").strip()
    host = raw_host or (request.url.hostname or "127.0.0.1")

    host_name = host.split(":")[0].lower()
    if forwarded_host and _is_demo_unreachable_host(host_name):
        # Origin saw localhost/LAN; use the public tunnel host Cloudflare sent.
        host = forwarded_host.split(":")[0]

    forwarded = (request.headers.get("x-forwarded-proto") or "").split(",")[0].strip()
    scheme = forwarded or request.url.scheme or "http"
    host_name = host.split(":")[0].lower()
    if any(host_name.endswith(s) for s in _TUNNEL_SUFFIXES):
        scheme = "https"
        host = host_name
    return f"{scheme}://{host}"


def _is_demo_unreachable_host(host: str) -> bool:
    h = (host or "").lower()
    if not h:
        return False
    if h in {"localhost", "127.0.0.1", "0.0.0.0"}:
        return True
    if any(h.endswith(s) for s in _TUNNEL_SUFFIXES):
        return True
    if h.startswith("10."):
        return True
    if h.startswith("192.168."):
        return True
    if h.startswith("172."):
        parts = h.split(".")
        if len(parts) >= 2 and parts[1].isdigit() and 16 <= int(parts[1]) <= 31:
            return True
    return False


def to_relative_media_path(url: str | None) -> str | None:
    """Collapse absolute media URLs to /media-files/... for durable storage."""
    if not url or not isinstance(url, str):
        return url
    trimmed = url.strip()
    if not trimmed:
        return url
    if "://" not in trimmed:
        if "media-files" in trimmed:
            path = trimmed if trimmed.startswith("/") else f"/{trimmed}"
            # Drop query for storage; posters may keep cache-busting at serve time.
            return path.split("?", 1)[0]
        return url
    parts = urlsplit(trimmed)
    if "/media-files" in parts.path or parts.path.startswith("/media/"):
        return parts.path
    return url


def absolutize_media_url(url: str | None, origin: str) -> str | None:
    """Point relative / stale private media URLs at the request's public origin."""
    if not url or not isinstance(url, str):
        return url
    trimmed = url.strip()
    if not trimmed:
        return url
    origin = origin.rstrip("/")

    if "://" not in trimmed:
        if "media-files" in trimmed or trimmed.startswith("/media"):
            path = trimmed if trimmed.startswith("/") else f"/{trimmed}"
            return f"{origin}{path}"
        return url

    parts = urlsplit(trimmed)
    if not parts.scheme or not parts.hostname:
        return url

    is_media = "/media-files" in parts.path or parts.path.startswith("/media/")
    host = parts.hostname
    origin_host = urlsplit(origin).hostname or ""
    if host == origin_host:
        return url
    if is_media or _is_demo_unreachable_host(host):
        # Keep path/query; swap scheme+host(+port) to the live origin.
        o = urlsplit(origin)
        return urlunsplit(
            (o.scheme, o.netloc, parts.path, parts.query, parts.fragment)
        )
    return url


def rewrite_media_tree(value: Any, origin: str) -> Any:
    if isinstance(value, str):
        return absolutize_media_url(value, origin)
    if isinstance(value, list):
        return [rewrite_media_tree(v, origin) for v in value]
    if isinstance(value, dict):
        return {k: rewrite_media_tree(v, origin) for k, v in value.items()}
    return value
