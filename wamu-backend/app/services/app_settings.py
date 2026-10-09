"""Admin-configurable key/value settings with env defaults."""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.models.settings import AppSetting

KEY_VIDEO_ARCHIVE_DAYS = "video_archive_after_days"
KEY_VIDEO_PURGE_DAYS = "video_purge_after_days"


async def get_setting(db: AsyncSession, key: str, default: str) -> str:
    row = await db.get(AppSetting, key)
    if row and row.value is not None and str(row.value).strip():
        return str(row.value).strip()
    return default


async def set_setting(db: AsyncSession, key: str, value: str) -> AppSetting:
    row = await db.get(AppSetting, key)
    if row is None:
        row = AppSetting(key=key, value=str(value))
        db.add(row)
    else:
        row.value = str(value)
    await db.flush()
    return row


async def get_video_retention(db: AsyncSession) -> dict[str, int]:
    cfg = get_settings()
    archive_raw = await get_setting(
        db, KEY_VIDEO_ARCHIVE_DAYS, str(cfg.video_archive_after_days)
    )
    purge_raw = await get_setting(
        db, KEY_VIDEO_PURGE_DAYS, str(cfg.video_purge_after_days)
    )
    try:
        archive_days = max(30, min(int(archive_raw), 730))
    except ValueError:
        archive_days = cfg.video_archive_after_days
    try:
        purge_days = max(archive_days + 30, min(int(purge_raw), 1825))
    except ValueError:
        purge_days = max(archive_days + 30, cfg.video_purge_after_days)
    return {
        "archive_after_days": archive_days,
        "purge_after_days": purge_days,
    }


async def set_video_retention(
    db: AsyncSession, *, archive_after_days: int, purge_after_days: int
) -> dict[str, int]:
    archive_after_days = max(30, min(int(archive_after_days), 730))
    purge_after_days = max(archive_after_days + 30, min(int(purge_after_days), 1825))
    await set_setting(db, KEY_VIDEO_ARCHIVE_DAYS, str(archive_after_days))
    await set_setting(db, KEY_VIDEO_PURGE_DAYS, str(purge_after_days))
    return {
        "archive_after_days": archive_after_days,
        "purge_after_days": purge_after_days,
    }
