"""Seed discover feed from video-demo clips (media_uploads/seed/demo).

Maps each clip to a matching Kampala shop category (bakery / food / fashion /
phones / grocery). Creates thin demo shops + products if missing.

Usage:
  python -m scripts.seed_discover_videos          # idempotent if demo clips already seeded
  python -m scripts.seed_discover_videos --force  # replace feed videos with demo set
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
from decimal import Decimal
from pathlib import Path

from sqlalchemy import delete, func, select

from app.core.config import get_settings
from app.core.database import AsyncSessionLocal
from app.models.business import (
    Business,
    BusinessMember,
    BusinessStatus,
    Category,
    Location,
    MemberRole,
    VerificationStatus,
)
from app.models.product import Product
from app.models.user import User, UserProfile, UserRole
from app.models.video import BusinessVideo, VideoLike
from app.services.utils import slugify

logger = logging.getLogger(__name__)

ROOT = Path(__file__).resolve().parents[1]
DEMO_DIR = ROOT / "media_uploads" / "seed" / "demo"
MANIFEST = DEMO_DIR / "manifest.json"

# shop_key → (name, category name, phone, product name, price UGX, lat, lng)
SHOPS = {
    "bakery": (
        "Fyncakes",
        "Cakes & Bakery",
        "+256700000001",
        "Custom cake",
        Decimal("45000"),
        Decimal("0.3476000"),
        Decimal("32.5825000"),
    ),
    "food": (
        "Nakawa Grill House",
        "Restaurants",
        "+256700000101",
        "Grill plate",
        Decimal("25000"),
        Decimal("0.3320000"),
        Decimal("32.6150000"),
    ),
    "fashion": (
        "Ntinda Style Hub",
        "Fashion",
        "+256700000102",
        "Ready-to-wear fit",
        Decimal("85000"),
        Decimal("0.3550000"),
        Decimal("32.6100000"),
    ),
    "phones": (
        "Phone Point Kampala",
        "Phones & Accessories",
        "+256700000103",
        "Phone accessory pack",
        Decimal("35000"),
        Decimal("0.3136000"),
        Decimal("32.5811000"),
    ),
    "grocery": (
        "Wandegeya Market Bags",
        "Groceries",
        "+256700000104",
        "Reusable market bag",
        Decimal("12000"),
        Decimal("0.3330000"),
        Decimal("32.5700000"),
    ),
}


async def _ensure_owner(db, phone: str, first: str, last: str) -> User:
    user = await db.scalar(
        select(User).where(User.phone == phone).options(
            # avoid lazy profile access
        )
    )
    if user:
        profile = await db.scalar(select(UserProfile).where(UserProfile.user_id == user.id))
        if profile is None:
            db.add(
                UserProfile(
                    user_id=user.id,
                    first_name=first,
                    last_name=last,
                    owns_business=True,
                    wants_to_buy=True,
                )
            )
            await db.flush()
        else:
            profile.owns_business = True
            await db.flush()
        return user
    user = User(phone=phone, phone_verified=True, role=UserRole.CUSTOMER.value)
    db.add(user)
    await db.flush()
    db.add(
        UserProfile(
            user_id=user.id,
            first_name=first,
            last_name=last,
            owns_business=True,
            wants_to_buy=True,
        )
    )
    await db.flush()
    return user


async def _ensure_shop(db, shop_key: str) -> Business:
    name, cat_name, phone, product_name, price, lat, lng = SHOPS[shop_key]
    existing = await db.scalar(
        select(Business).where(Business.name == name, Business.deleted_at.is_(None))
    )
    if existing:
        # Ensure at least one active product for Chat-to-Order pricing
        slug = slugify(f"{name}-{product_name}")
        prod = await db.scalar(
            select(Product).where(
                Product.business_id == existing.id,
                Product.deleted_at.is_(None),
                Product.is_active.is_(True),
            )
        )
        same_slug = await db.scalar(
            select(Product).where(
                Product.business_id == existing.id,
                Product.slug == slug,
            )
        )
        if same_slug:
            if not same_slug.is_active:
                same_slug.is_active = True
            return existing
        if not prod:
            db.add(
                Product(
                    business_id=existing.id,
                    name=product_name,
                    slug=slug,
                    price=price,
                    currency="UGX",
                    stock_quantity=50,
                    is_active=True,
                )
            )
            await db.flush()
        return existing

    cat = await db.scalar(select(Category).where(Category.name == cat_name))
    owner = await _ensure_owner(db, phone, name.split()[0], "Owner")
    biz = Business(
        owner_id=owner.id,
        name=name,
        slug=slugify(name),
        description=f"{name} on Wamu — Chat to Order from Discover.",
        phone=phone,
        payout_phone=phone,
        payout_provider="MTN",
        category_id=cat.id if cat else None,
        status=BusinessStatus.ACTIVE.value,
        verification_status=VerificationStatus.VERIFIED.value,
    )
    db.add(biz)
    await db.flush()
    db.add(
        BusinessMember(
            business_id=biz.id,
            user_id=owner.id,
            role=MemberRole.OWNER.value,
            is_active=True,
        )
    )
    db.add(
        Location(
            business_id=biz.id,
            address_line=f"{name}, Kampala",
            city="Kampala",
            latitude=lat,
            longitude=lng,
            country="UG",
        )
    )
    db.add(
        Product(
            business_id=biz.id,
            name=product_name,
            slug=slugify(f"{name}-{product_name}"),
            price=price,
            currency="UGX",
            stock_quantity=50,
            is_active=True,
        )
    )
    await db.flush()
    logger.info("Created demo shop %s (%s)", name, shop_key)
    return biz


async def seed_discover_videos(*, force: bool = False) -> int:
    settings = get_settings()
    if settings.is_production and not force:
        logger.info("Skip discover video seed in production")
        return 0

    if not MANIFEST.is_file():
        logger.info("No demo manifest at %s — skip", MANIFEST)
        return 0

    clips = json.loads(MANIFEST.read_text())
    if not clips:
        return 0

    async with AsyncSessionLocal() as db:
        # Already seeded these demo paths?
        sample = await db.scalar(
            select(BusinessVideo.id).where(
                BusinessVideo.video_url.contains("/media-files/seed/demo/")
            )
        )
        if sample and not force:
            logger.info("Demo discover videos already present — skip")
            return 0

        shop_cache: dict[str, Business] = {}
        for key in SHOPS:
            shop_cache[key] = await _ensure_shop(db, key)

        if force or sample:
            # Replace prior feed (likes cascade via FK may need manual clear)
            ids = (
                await db.scalars(select(BusinessVideo.id))
            ).all()
            if ids:
                await db.execute(delete(VideoLike).where(VideoLike.video_id.in_(ids)))
                await db.execute(delete(BusinessVideo))
                logger.info("Cleared %s prior discover videos", len(ids))

        # Always store relative /media-files paths — request middleware + the
        # Flutter client rewrite them to the live tunnel/LAN origin.
        created = 0
        for i, clip in enumerate(clips):
            shop_key = clip.get("shop") or "food"
            biz = shop_cache.get(shop_key) or shop_cache["food"]
            video_path = clip["video"]
            poster_path = clip.get("poster")
            mp4 = ROOT / "media_uploads" / video_path
            if not mp4.is_file():
                logger.warning("Missing clip file %s", mp4)
                continue
            db.add(
                BusinessVideo(
                    business_id=biz.id,
                    author_id=biz.owner_id,
                    caption=clip.get("caption"),
                    video_url=f"/media-files/{video_path}",
                    poster_url=(
                        f"/media-files/{poster_path}" if poster_path else None
                    ),
                    tags=clip.get("tags"),
                    sort_order=i,
                    is_active=True,
                )
            )
            created += 1

        await db.commit()
        total = await db.scalar(select(func.count()).select_from(BusinessVideo))
        logger.info("Seeded %s demo discover videos (feed total=%s)", created, total)
        return created


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    p = argparse.ArgumentParser()
    p.add_argument("--force", action="store_true", help="Replace existing feed videos")
    args = p.parse_args()
    n = asyncio.run(seed_discover_videos(force=args.force))
    print(f"seeded={n}")


if __name__ == "__main__":
    main()
