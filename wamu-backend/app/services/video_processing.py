"""Compress short videos + extract posters with ffmpeg (mobile-friendly delivery)."""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from app.core.config import get_settings

logger = logging.getLogger(__name__)

# Prefer project-bundled static build, then PATH.
_FFMPEG_CANDIDATES = [
    Path(__file__).resolve().parents[3] / ".tools" / "ffmpeg-7.0.2-amd64-static" / "ffmpeg",
    Path(__file__).resolve().parents[2].parent / ".tools" / "ffmpeg-7.0.2-amd64-static" / "ffmpeg",
]


def ffmpeg_bin() -> str | None:
    settings = get_settings()
    configured = (settings.ffmpeg_path or "").strip()
    if configured and Path(configured).is_file():
        return configured
    for cand in _FFMPEG_CANDIDATES:
        if cand.is_file():
            return str(cand)
    which = shutil.which("ffmpeg")
    return which


def ffprobe_bin() -> str | None:
    """Resolve ffprobe next to ffmpeg, or from PATH."""
    ff = ffmpeg_bin()
    if ff:
        probe = Path(ff).with_name("ffprobe")
        if probe.is_file():
            return str(probe)
    return shutil.which("ffprobe")


def _run(cmd: list[str], *, timeout: int = 180) -> None:
    subprocess.run(
        cmd,
        check=True,
        capture_output=True,
        timeout=timeout,
    )


def probe_duration_seconds(path: Path) -> float | None:
    """Return media duration in seconds, or None if unreadable."""
    probe = ffprobe_bin()
    if not probe or not path.is_file():
        return None
    try:
        out = subprocess.run(
            [
                probe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        raw = (out.stdout or "").strip()
        if not raw or raw.upper() == "N/A":
            return None
        return float(raw)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, ValueError) as exc:
        logger.warning("ffprobe duration failed: %s", exc)
        return None


class VideoDurationError(ValueError):
    """Raised when a short is longer than the allowed maximum (1.5 minutes)."""


def assert_short_duration(seconds: float | None) -> int:
    """Validate Discover short length: up to max seconds (default 90). Returns whole seconds."""
    settings = get_settings()
    lo = int(settings.video_min_duration_seconds)
    hi = int(settings.video_max_duration_seconds)
    if seconds is None:
        raise VideoDurationError(
            f"Could not read video length. Shorts must be at most {hi} seconds (1.5 minutes)."
        )
    rounded = int(round(seconds))
    if rounded < lo:
        raise VideoDurationError(
            f"Could not use this file as a short (about {rounded}s). "
            f"Upload a real video clip of at most {hi} seconds (1.5 minutes)."
        )
    if rounded > hi:
        raise VideoDurationError(
            f"Shorts must be at most {hi} seconds (1.5 minutes). "
            f"This clip is about {rounded}s."
        )
    return rounded


def extract_poster(video_path: Path, poster_path: Path) -> bool:
    """Grab a JPEG frame ~1s in. Returns True on success."""
    ff = ffmpeg_bin()
    if not ff or not video_path.is_file():
        return False
    poster_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        _run(
            [
                ff,
                "-y",
                "-ss",
                "1",
                "-i",
                str(video_path),
                "-frames:v",
                "1",
                "-q:v",
                "4",
                str(poster_path),
            ],
            timeout=60,
        )
        return poster_path.is_file() and poster_path.stat().st_size > 0
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as exc:
        logger.warning("poster extract failed: %s", exc)
        return False


def compress_mp4(
    src: Path,
    dest: Path,
    *,
    max_height: int | None = None,
    crf: int | None = None,
) -> bool:
    """
    Transcode to H.264 + AAC in a progressive MP4 (faststart) for quick first-play.
    Returns True when dest is written and smaller-or-equal vs a sensible encode.
    """
    ff = ffmpeg_bin()
    if not ff or not src.is_file():
        return False
    settings = get_settings()
    height = max_height or settings.video_max_height
    use_crf = crf if crf is not None else settings.video_crf
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(".tmp.mp4")
    try:
        _run(
            [
                ff,
                "-y",
                "-i",
                str(src),
                "-vf",
                f"scale=-2:min({height}\\,ih)",
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-crf",
                str(use_crf),
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-b:a",
                "96k",
                "-movflags",
                "+faststart",
                "-shortest",
                str(tmp),
            ],
            timeout=300,
        )
        if not tmp.is_file() or tmp.stat().st_size < 1024:
            tmp.unlink(missing_ok=True)
            return False
        # Keep original if encode somehow ballooned.
        if tmp.stat().st_size > src.stat().st_size * 1.05:
            tmp.unlink(missing_ok=True)
            if src.resolve() != dest.resolve():
                shutil.copy2(src, dest)
            return False
        os.replace(tmp, dest)
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as exc:
        logger.warning("video compress failed: %s", exc)
        tmp.unlink(missing_ok=True)
        return False


def process_uploaded_video_bytes(
    data: bytes,
) -> tuple[bytes, bytes | None, str, int | None]:
    """
    Validate short duration, compress + extract poster JPEG.
    Returns (video_bytes, poster_jpeg_or_None, mime_type, duration_seconds).
    Falls back to original bytes when ffmpeg is unavailable (still requires duration).
    """
    with tempfile.TemporaryDirectory(prefix="wamu_vid_") as td:
        raw = Path(td) / "raw.bin"
        out = Path(td) / "out.mp4"
        poster = Path(td) / "poster.jpg"
        raw.write_bytes(data)
        duration = probe_duration_seconds(raw)
        duration_s = assert_short_duration(duration)

        ff = ffmpeg_bin()
        if not ff:
            return data, None, "video/mp4", duration_s

        ok = compress_mp4(raw, out)
        video_out = out.read_bytes() if ok and out.is_file() else data
        poster_bytes = None
        src_for_poster = out if ok and out.is_file() else raw
        if extract_poster(src_for_poster, poster):
            poster_bytes = poster.read_bytes()
        return video_out, poster_bytes, "video/mp4", duration_s


def media_path_from_url(video_url: str) -> Path | None:
    from urllib.parse import urlsplit

    path = urlsplit(video_url or "").path
    if "/media-files/" not in path:
        return None
    rel = path.split("/media-files/", 1)[1]
    root = Path(__file__).resolve().parents[2] / "media_uploads"
    f = root / rel
    return f if f.is_file() else None
