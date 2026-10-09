"""Apply WAMU_media_mapping.xlsx → media files + DB shops/products/videos.

Reads media_uploads/seed/mapping/{images,videos}.json (exported from the xlsx),
copies assets under clean filenames, then seeds merchants by category.

Usage:
  python -m scripts.apply_media_mapping
  python -m scripts.apply_media_mapping --seed
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import re
import shutil
import time
from decimal import Decimal
from pathlib import Path

from PIL import Image
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
from app.models.product import Product, ProductImage
from app.models.user import User, UserProfile, UserRole
from app.models.video import BusinessVideo, VideoLike
from app.services.utils import slugify

logger = logging.getLogger(__name__)

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
IMAGES_SRC = REPO / "images_demo"
VIDEOS_SRC = REPO / "video-demo"
MAP_DIR = ROOT / "media_uploads" / "seed" / "mapping"
MAPPED_IMG = ROOT / "media_uploads" / "seed" / "mapped"
DEMO_DIR = ROOT / "media_uploads" / "seed" / "demo"
SHOPS_DIR = ROOT / "media_uploads" / "seed" / "shops"

# Category prefix → shop key
SHOP_META: dict[str, tuple[str, str, str, Decimal, Decimal]] = {
    # key: (shop name, category name, owner phone, lat, lng)
    "phones": (
        "Phone Point Kampala",
        "Phones & Accessories",
        "+256700000103",
        Decimal("0.3136000"),
        Decimal("32.5811000"),
    ),
    "food": (
        "Nakawa Grill House",
        "Restaurants",
        "+256700000101",
        Decimal("0.3320000"),
        Decimal("32.6150000"),
    ),
    "bakery": (
        "Fyncakes",
        "Cakes & Bakery",
        "+256700000001",
        Decimal("0.3476000"),
        Decimal("32.5825000"),
    ),
    "fashion": (
        "Ntinda Style Hub",
        "Fashion",
        "+256700000102",
        Decimal("0.3550000"),
        Decimal("32.6100000"),
    ),
    "grocery": (
        "Wandegeya Fresh Market",
        "Groceries",
        "+256700000104",
        Decimal("0.3330000"),
        Decimal("32.5700000"),
    ),
    "cars": (
        "Kampala Auto Yard",
        "Automotive",
        "+256700000105",
        Decimal("0.3200000"),
        Decimal("32.5800000"),
    ),
    "furniture": (
        "Home & Living Kampala",
        "Furniture",
        "+256700000106",
        Decimal("0.3400000"),
        Decimal("32.5900000"),
    ),
    "realestate": (
        "Pearl Homes Realty",
        "Real Estate",
        "+256700000107",
        Decimal("0.3500000"),
        Decimal("32.6000000"),
    ),
}


def _shop_key(category: str) -> str:
    c = (category or "").lower()
    # Food / cakes before furniture — "dining" must not map Food & Dining → furniture.
    if "smartphone" in c or "electronics" in c or "mobile" in c or "photograph" in c:
        return "phones"
    if "cake" in c or "baking" in c or "pastry" in c or "snack" in c:
        return "bakery" if ("cake" in c or "baking" in c or "pastry" in c) else "food"
    if "food" in c or "dining" in c or "chicken" in c or "breakfast" in c or "cook" in c:
        return "food"
    if "fashion" in c or "clothing" in c or "bag" in c:
        return "fashion"
    if "grocery" in c or "fruit" in c or "beverage" in c or "soft drink" in c:
        return "grocery"
    if "automotive" in c or ("car" in c and "cart" not in c):
        return "cars"
    if "furniture" in c or "living room" in c or "bedroom" in c or (
        "dining" in c and "food" not in c
    ):
        return "furniture"
    if "real estate" in c or "property" in c or "home & interior" in c:
        return "realestate"
    if "interior" in c and "cake" not in c:
        return "realestate"
    if "business" in c or "retail" in c:
        # Shopping-bag / retail creatives browse better under fashion merchants.
        return "fashion"
    return "food"


def _product_name(new_filename: str) -> str:
    stem = Path(new_filename).stem
    stem = re.sub(r"[_-]+", " ", stem)
    stem = re.sub(r"\s+\d+$", "", stem)
    return stem.strip().title()


def _to_jpeg(src: Path, dest: Path) -> bool:
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        if src.suffix.lower() in {".jpg", ".jpeg"}:
            shutil.copy2(src, dest)
            return True
        with Image.open(src) as im:
            im.convert("RGB").save(dest, "JPEG", quality=88)
        return True
    except Exception as e:  # noqa: BLE001
        logger.warning("Skip image %s: %s", src.name, e)
        return False


def materialize_assets() -> tuple[list[dict], list[dict]]:
    images = json.loads((MAP_DIR / "images.json").read_text())
    videos = json.loads((MAP_DIR / "videos.json").read_text())
    MAPPED_IMG.mkdir(parents=True, exist_ok=True)
    DEMO_DIR.mkdir(parents=True, exist_ok=True)
    SHOPS_DIR.mkdir(parents=True, exist_ok=True)

    ok_img = 0
    for row in images:
        src_name = row.get("source") or row["old"]
        src = IMAGES_SRC / src_name
        if not src.is_file():
            logger.warning("Missing image source %s", src_name)
            continue
        new_stem = Path(row["new"]).stem + ".jpg"
        dest = MAPPED_IMG / new_stem
        if _to_jpeg(src, dest):
            row["rel"] = f"seed/mapped/{new_stem}"
            row["shop"] = _shop_key(row["category"])
            ok_img += 1

    ok_vid = 0
    # Prefer matching content-aware: use source file, store under new name
    for row in videos:
        src_name = row.get("source") or row["old"]
        src = VIDEOS_SRC / src_name
        if not src.is_file():
            logger.warning("Missing video source %s", src_name[:80])
            continue
        new_name = Path(row["new"]).name
        if not new_name.lower().endswith(".mp4"):
            new_name = Path(row["new"]).stem + ".mp4"
        dest = DEMO_DIR / new_name
        shutil.copy2(src, dest)
        # Poster: reuse a mapped image from same shop category if available
        row["rel"] = f"seed/demo/{new_name}"
        row["shop"] = _shop_key(row["category"])
        ok_vid += 1

    # Shop covers/logos from non-priced visuals (or first product image)
    by_shop: dict[str, list[dict]] = {k: [] for k in SHOP_META}
    for row in images:
        if row.get("rel"):
            by_shop.setdefault(row["shop"], []).append(row)

    for shop, rows in by_shop.items():
        visuals = [r for r in rows if not r.get("price")]
        products = [r for r in rows if r.get("price")]
        cover_src = (visuals or products or [None])[0]
        logo_src = (visuals[1:] or visuals or products or [None])
        logo_src = logo_src[0] if logo_src else cover_src
        if cover_src and cover_src.get("rel"):
            src = ROOT / "media_uploads" / cover_src["rel"]
            if src.is_file():
                shutil.copy2(src, SHOPS_DIR / f"{shop}_cover.jpg")
        if logo_src and logo_src.get("rel"):
            src = ROOT / "media_uploads" / logo_src["rel"]
            if src.is_file():
                shutil.copy2(src, SHOPS_DIR / f"{shop}_logo.jpg")

    # Video posters from shop product stills
    posters_by_shop = {
        k: [r["rel"] for r in rows if r.get("price") and r.get("rel")]
        for k, rows in by_shop.items()
    }
    for i, row in enumerate(videos):
        if not row.get("rel"):
            continue
        shop = row["shop"]
        pool = posters_by_shop.get(shop) or [
            r["rel"] for r in images if r.get("rel")
        ]
        poster_rel = None
        if pool:
            poster_rel = pool[i % len(pool)]
            poster_src = ROOT / "media_uploads" / poster_rel
            poster_name = Path(row["new"]).stem + ".jpg"
            poster_dest = DEMO_DIR / poster_name
            if poster_src.is_file():
                shutil.copy2(poster_src, poster_dest)
                row["poster"] = f"seed/demo/{poster_name}"

    (MAP_DIR / "images.json").write_text(json.dumps(images, indent=2) + "\n")
    (MAP_DIR / "videos.json").write_text(json.dumps(videos, indent=2) + "\n")
    logger.info("Materialized images=%s videos=%s", ok_img, ok_vid)
    return images, videos


async def _ensure_owner(db, phone: str, first: str, last: str) -> User:
    user = await db.scalar(select(User).where(User.phone == phone))
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


async def _ensure_category(db, name: str) -> Category:
    cat = await db.scalar(select(Category).where(Category.name == name))
    if cat:
        cat.is_active = True
        return cat
    cat = Category(name=name, slug=slugify(name)[:120], is_active=True)
    db.add(cat)
    await db.flush()
    return cat


async def _ensure_shop(db, key: str) -> Business:
    name, cat_name, phone, lat, lng = SHOP_META[key]
    owner = await _ensure_owner(db, phone, name.split()[0], "Merchant")
    cat = await _ensure_category(db, cat_name)
    biz = await db.scalar(select(Business).where(Business.name == name))
    if biz is None:
        biz = Business(
            owner_id=owner.id,
            name=name,
            slug=slugify(name)[:220],
            description=f"{name} on Wamu — order via Chat.",
            phone=phone,
            category_id=cat.id,
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
                address_line="Kampala",
                city="Kampala",
                country="UG",
                latitude=lat,
                longitude=lng,
            )
        )
        await db.flush()
    else:
        biz.status = BusinessStatus.ACTIVE.value
        biz.category_id = cat.id
        biz.verification_status = VerificationStatus.VERIFIED.value
        await db.flush()
    return biz


async def seed_from_mapping(images: list[dict], videos: list[dict]) -> None:
    settings = get_settings()
    public = settings.public_media_base.rstrip("/")
    bust = int(time.time())

    async with AsyncSessionLocal() as db:
        shop_cache: dict[str, Business] = {}
        for key in SHOP_META:
            shop_cache[key] = await _ensure_shop(db, key)

        # Soft-deactivate other active businesses without media later via cover check
        for key, biz in shop_cache.items():
            logo = SHOPS_DIR / f"{key}_logo.jpg"
            cover = SHOPS_DIR / f"{key}_cover.jpg"
            if logo.is_file():
                biz.logo_url = f"{public}/media-files/seed/shops/{key}_logo.jpg?v={bust}"
            if cover.is_file():
                biz.cover_url = f"{public}/media-files/seed/shops/{key}_cover.jpg?v={bust}"
            # Prefer cover from visuals; fall back to logo
            if not biz.cover_url and biz.logo_url:
                biz.cover_url = biz.logo_url
            biz.status = BusinessStatus.ACTIVE.value

        # Deactivate every product first, then reactivate only mapped ones.
        all_products = (
            await db.scalars(select(Product).where(Product.deleted_at.is_(None)))
        ).all()
        for p in all_products:
            p.is_active = False

        created_products = 0
        for row in images:
            price = row.get("price")
            rel = row.get("rel")
            if not price or not rel:
                continue
            shop = row.get("shop") or _shop_key(row["category"])
            biz = shop_cache[shop]
            name = _product_name(row["new"])
            desc = (row.get("description") or "").strip() or None
            existing = await db.scalar(
                select(Product).where(
                    Product.business_id == biz.id,
                    Product.name == name,
                    Product.deleted_at.is_(None),
                )
            )
            if existing is None:
                existing = Product(
                    business_id=biz.id,
                    name=name,
                    slug=slugify(f"{biz.name}-{name}")[:220],
                    description=desc,
                    price=Decimal(str(price)),
                    currency="UGX",
                    stock_quantity=40,
                    is_active=True,
                )
                db.add(existing)
                await db.flush()
            else:
                existing.description = desc
                existing.price = Decimal(str(price))
                existing.is_active = True

            url = f"{public}/media-files/{rel}?v={bust}"
            img = await db.scalar(
                select(ProductImage).where(
                    ProductImage.product_id == existing.id,
                    ProductImage.is_primary.is_(True),
                )
            )
            if img is None:
                db.add(
                    ProductImage(
                        product_id=existing.id,
                        url=url,
                        mime_type="image/jpeg",
                        sort_order=0,
                        is_primary=True,
                    )
                )
            else:
                img.url = url
            created_products += 1

        # Discover videos — replace feed
        ids = (await db.scalars(select(BusinessVideo.id))).all()
        if ids:
            await db.execute(delete(VideoLike).where(VideoLike.video_id.in_(ids)))
            await db.execute(delete(BusinessVideo))

        created_videos = 0
        # Stable browse order: category groups, then spreadsheet order.
        ordered = sorted(
            [r for r in videos if r.get("rel")],
            key=lambda r: (
                (r.get("category") or "").split("/")[0].lower(),
                int(str(r.get("no") or "0") or 0),
            ),
        )
        for i, row in enumerate(ordered):
            shop = row.get("shop") or _shop_key(row["category"])
            biz = shop_cache.get(shop) or shop_cache["food"]
            poster = row.get("poster")
            title = _product_name(row.get("new") or "Wamu video")
            description = (row.get("description") or "").strip()
            caption = f"{title}|||{description}" if description else title
            db.add(
                BusinessVideo(
                    business_id=biz.id,
                    author_id=biz.owner_id,
                    caption=caption,
                    video_url=f"/media-files/{row['rel']}",
                    poster_url=(
                        f"/media-files/{poster}?v={bust}" if poster else None
                    ),
                    tags=(row.get("category") or "").strip() or None,
                    sort_order=i,
                    is_active=True,
                )
            )
            created_videos += 1

        await db.commit()
        total_p = await db.scalar(
            select(func.count()).select_from(Product).where(Product.is_active.is_(True))
        )
        total_v = await db.scalar(select(func.count()).select_from(BusinessVideo))
        logger.info(
            "Seeded products=%s (active=%s) videos=%s shops=%s",
            created_products,
            total_p,
            created_videos,
            len(shop_cache),
        )


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    p = argparse.ArgumentParser()
    p.add_argument("--seed", action="store_true", help="Write DB after materializing")
    args = p.parse_args()
    images, videos = materialize_assets()
    if args.seed:
        asyncio.run(seed_from_mapping(images, videos))
        print("mapping_seeded=ok")
    else:
        print(f"materialized images={len(images)} videos={len(videos)}")


if __name__ == "__main__":
    main()
