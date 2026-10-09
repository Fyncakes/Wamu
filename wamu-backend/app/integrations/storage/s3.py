"""S3-compatible object storage (MinIO) with local filesystem fallback for demo.

Never store blobs in Postgres — only URLs/keys.
"""

from __future__ import annotations

import logging
import uuid
from pathlib import Path

import boto3
from botocore.client import Config
from botocore.exceptions import BotoCoreError, ClientError

from app.core.config import get_settings

settings = get_settings()
logger = logging.getLogger(__name__)

# Local fallback directory (used when MinIO is unreachable)
_LOCAL_MEDIA_ROOT = Path(__file__).resolve().parents[3] / "media_uploads"

# After the first failed S3 attempt in a process, skip further remote tries
# so demo uploads don't spam botocore connection-refused tracebacks.
_s3_disabled_runtime = False


def _client():
    return boto3.client(
        "s3",
        endpoint_url=settings.s3_endpoint_url,
        aws_access_key_id=settings.s3_access_key,
        aws_secret_access_key=settings.s3_secret_key,
        region_name=settings.s3_region,
        config=Config(
            signature_version="s3v4",
            connect_timeout=2,
            read_timeout=5,
            retries={"max_attempts": 1},
        ),
    )


def _local_upload(data: bytes, *, content_type: str, folder: str) -> tuple[str, str]:
    """Write to disk and return a URL served by FastAPI StaticFiles."""
    ext = {
        "image/jpeg": ".jpg",
        "image/jpg": ".jpg",
        "image/png": ".png",
        "image/webp": ".webp",
        "image/gif": ".gif",
        "audio/mp4": ".m4a",
        "audio/m4a": ".m4a",
        "audio/aac": ".aac",
        "audio/mpeg": ".mp3",
        "audio/webm": ".webm",
        "audio/ogg": ".ogg",
        "audio/wav": ".wav",
        "video/webm": ".webm",
        "video/mp4": ".mp4",
    }.get(content_type.split(";")[0].strip().lower(), "")
    key = f"{folder}/{uuid.uuid4().hex}{ext}"
    dest = _LOCAL_MEDIA_ROOT / key
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    # Relative path — API middleware / clients pin to the live tunnel or LAN origin.
    url = f"/media-files/{key}"
    return url, key


def upload_bytes(data: bytes, *, content_type: str, folder: str = "uploads") -> tuple[str, str]:
    """Returns (public_url, object_key). Falls back to local disk in development."""
    global _s3_disabled_runtime

    if not settings.s3_enabled or _s3_disabled_runtime:
        return _local_upload(data, content_type=content_type, folder=folder)

    key = f"{folder}/{uuid.uuid4().hex}"
    try:
        client = _client()
        client.put_object(
            Bucket=settings.s3_bucket,
            Key=key,
            Body=data,
            ContentType=content_type,
        )
        url = f"{settings.s3_public_url.rstrip('/')}/{settings.s3_bucket}/{key}"
        return url, key
    except (BotoCoreError, ClientError, OSError) as exc:
        if settings.environment == "production":
            raise
        _s3_disabled_runtime = True
        logger.warning(
            "S3 unreachable (%s) — using local media for this process",
            type(exc).__name__,
        )
        return _local_upload(data, content_type=content_type, folder=folder)
