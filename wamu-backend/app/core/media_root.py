"""On-disk media directory.

Railway sets MEDIA_ROOT to a mounted volume so shop photos and clips survive
a redeploy. Without that variable, files stay in the image's media_uploads folder.
"""

from __future__ import annotations

import os
from pathlib import Path
from urllib.parse import urlsplit

def media_root() -> Path:
    override = os.environ.get("MEDIA_ROOT", "").strip()
    if override:
        root = Path(override)
    else:
        root = Path(__file__).resolve().parents[2] / "media_uploads"
    root.mkdir(parents=True, exist_ok=True)
    return root


def media_file_from_url(url: str | None) -> Path | None:
    path = urlsplit(url or "").path
    if "/media-files/" not in path:
        return None
    rel = path.split("/media-files/", 1)[1]
    if not rel or ".." in Path(rel).parts:
        return None
    file_path = media_root() / rel
    return file_path if file_path.is_file() else None


def local_media_missing(url: str | None) -> bool:
    """True when a URL points at our disk and that file is not there."""
    if not url or "/media-files/" not in url:
        return False
    return media_file_from_url(url) is None


def live_shop_image(url: str | None) -> bool:
    """A shop photo customers can actually load (not a missing seed file)."""
    if not url or "/seed/" in url:
        return False
    if "/media-files/" in url:
        return media_file_from_url(url) is not None
    return url.startswith("http://") or url.startswith("https://")
