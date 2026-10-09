"""Attach modern demo shop logos, covers, and product stills from images_demo.

Reads media_uploads/seed/shops/manifest.json and updates the five demo shops
(Fyncakes, Nakawa Grill House, Ntinda Style Hub, Phone Point Kampala,
Wandegeya Market Bags).

Also deactivates products without a primary image and soft-hides businesses
that have neither logo nor cover (except the seeded demo shops).

Usage:
  python -m scripts.seed_demo_images
  python -m scripts.seed_demo_images --force
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import time
from decimal import Decimal
from pathlib import Path

from sqlalchemy import select

from app.core.config import get_settings
from app.core.database import AsyncSessionLocal
from app.models.business import Business, BusinessStatus
from app.models.product import Product, ProductImage
from app.services.utils import slugify
from scripts.seed_discover_videos import SHOPS, _ensure_shop

logger = logging.getLogger(__name__)

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "media_uploads" / "seed" / "shops" / "manifest.json"


async def _deactivate_imageless(db) -> tuple[int, int]:
    """Only tidy *seed/demo* shops — never hide live tester merchant products."""
    demo_names = {meta[0] for meta in SHOPS.values()}
    demo_business_ids = set(
        (
            await db.scalars(select(Business.id).where(Business.name.in_(demo_names)))
        ).all()
    )
    deactivated_products = 0
    if demo_business_ids:
        products = (
            await db.scalars(
                select(Product).where(
                    Product.deleted_at.is_(None),
                    Product.business_id.in_(demo_business_ids),
                )
            )
        ).all()
        for prod in products:
            img = await db.scalar(
                select(ProductImage).where(
                    ProductImage.product_id == prod.id,
                    ProductImage.is_primary.is_(True),
                )
            )
            has_url = bool(img and (img.url or "").strip())
            if not has_url and prod.is_active:
                prod.is_active = False
                deactivated_products += 1

    # Never soft-hide live tester businesses (they get default logos on create).
    return deactivated_products, 0


async def seed_demo_images(*, force: bool = False) -> int:
    settings = get_settings()
    if settings.is_production and not force:
        logger.info("Skip demo images in production")
        return 0
    if not MANIFEST.is_file():
        logger.info("No shops manifest at %s", MANIFEST)
        return 0

    data = json.loads(MANIFEST.read_text())
    public = settings.public_media_base.rstrip("/")
    updated = 0

    async with AsyncSessionLocal() as db:
        for shop_key in SHOPS:
            entry = data.get(shop_key)
            if not entry:
                continue
            biz = await _ensure_shop(db, shop_key)
            logo = entry.get("logo")
            cover = entry.get("cover")
            # Cache-bust cover/logo so phones pick up refreshed shop imagery.
            bust = int(time.time()) if force else None
            if logo and (force or not biz.logo_url):
                url = f"{public}/media-files/{logo}"
                biz.logo_url = f"{url}?v={bust}" if bust else url
            if cover and (force or not biz.cover_url):
                url = f"{public}/media-files/{cover}"
                biz.cover_url = f"{url}?v={bust}" if bust else url
            # Every active demo shop must keep a cover for the merchant page hero.
            if not (biz.cover_url or "").strip() and (biz.logo_url or "").strip():
                biz.cover_url = biz.logo_url
            biz.status = BusinessStatus.ACTIVE.value
            updated += 1

            for i, prod in enumerate(entry.get("products") or []):
                name = prod["name"]
                price = Decimal(str(prod["price"]))
                image = prod.get("image")
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
                        description=prod.get("description")
                        or f"{name} — available from {biz.name} on Wamu. Chat to order.",
                        price=price,
                        currency="UGX",
                        stock_quantity=40,
                        is_active=True,
                    )
                    db.add(existing)
                    await db.flush()
                else:
                    existing.price = price
                    existing.is_active = True
                    if force or not (existing.description or "").strip():
                        existing.description = prod.get("description") or (
                            f"{name} — available from {biz.name} on Wamu. Chat to order."
                        )

                if not image:
                    continue
                url = f"{public}/media-files/{image}"
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
                            sort_order=i,
                            is_primary=True,
                        )
                    )
                elif force or not img.url:
                    img.url = url

        off_p, off_b = await _deactivate_imageless(db)
        await db.commit()
        logger.info(
            "Updated imagery for %s demo shops; deactivated products=%s businesses=%s",
            updated,
            off_p,
            off_b,
        )
        return updated


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    p = argparse.ArgumentParser()
    p.add_argument("--force", action="store_true")
    args = p.parse_args()
    n = asyncio.run(seed_demo_images(force=args.force))
    print(f"shops_imaged={n}")


if __name__ == "__main__":
    main()
