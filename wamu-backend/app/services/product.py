"""Product and search services — Postgres ILIKE/ranking for MVP (OpenSearch later)."""

from __future__ import annotations

import uuid
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import case, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.business import Business, MemberRole
from app.models.product import Product, ProductImage, ProductStatus
from app.models.user import User
from app.schemas.marketplace import ProductCreate, ProductUpdate
from app.services.business import assert_business_member
from app.services.utils import slugify


async def create_product(
    db: AsyncSession, user: User, business_id: uuid.UUID, data: ProductCreate
) -> Product:
    await assert_business_member(
        db, user, business_id, {MemberRole.OWNER.value, MemberRole.MANAGER.value, MemberRole.STAFF.value}
    )
    if data.currency != "UGX":
        raise HTTPException(status_code=400, detail="Only UGX supported in MVP")
    base_slug = slugify(data.name) or "product"
    slug = base_slug
    i = 1
    while True:
        exists = await db.scalar(
            select(Product.id).where(
                Product.business_id == business_id,
                Product.slug == slug,
                Product.deleted_at.is_(None),
            )
        )
        if not exists:
            break
        i += 1
        slug = f"{base_slug}-{i}"
    product = Product(
        business_id=business_id,
        category_id=data.category_id,
        name=data.name,
        slug=slug,
        description=data.description,
        price=data.price,
        currency="UGX",
        stock_quantity=data.stock_quantity,
        status=ProductStatus.ACTIVE.value,
    )
    db.add(product)
    await db.flush()
    result = await db.execute(
        select(Product).options(selectinload(Product.images)).where(Product.id == product.id)
    )
    return result.scalar_one()


async def list_products(
    db: AsyncSession,
    *,
    business_id: uuid.UUID | None = None,
    page: int = 1,
    page_size: int = 20,
    require_image: bool = True,
) -> tuple[list[Product], int]:
    page_size = min(max(page_size, 1), 100)
    filters = [
        Product.deleted_at.is_(None),
        Product.is_active.is_(True),
    ]
    if require_image:
        # Any saved photo counts — buyers must see items after a successful upload.
        # (Older filter required is_primary only and hid valid listings.)
        filters.append(
            Product.id.in_(
                select(ProductImage.product_id).where(
                    ProductImage.url.is_not(None),
                    ProductImage.url != "",
                )
            )
        )
    stmt = select(Product).options(selectinload(Product.images)).where(*filters)
    count_stmt = select(func.count()).select_from(Product).where(*filters)
    if business_id:
        stmt = stmt.where(Product.business_id == business_id)
        count_stmt = count_stmt.where(Product.business_id == business_id)
    total = await db.scalar(count_stmt) or 0
    rows = (
        await db.execute(
            stmt.order_by(Product.created_at.desc())
            .offset((page - 1) * page_size)
            .limit(page_size)
        )
    ).scalars().all()
    return list(rows), int(total)


async def list_owner_products(
    db: AsyncSession,
    user: User,
    business_id: uuid.UUID,
) -> list[Product]:
    """All products for a shop the user manages (incl. inactive / no photo yet)."""
    await assert_business_member(
        db,
        user,
        business_id,
        {MemberRole.OWNER.value, MemberRole.MANAGER.value, MemberRole.STAFF.value},
    )
    rows = (
        await db.execute(
            select(Product)
            .options(selectinload(Product.images))
            .where(
                Product.business_id == business_id,
                Product.deleted_at.is_(None),
            )
            .order_by(Product.created_at.desc())
            .limit(100)
        )
    ).scalars().all()
    return list(rows)


async def get_product(db: AsyncSession, product_id: uuid.UUID) -> Product:
    result = await db.execute(
        select(Product)
        .options(selectinload(Product.images))
        .where(Product.id == product_id, Product.deleted_at.is_(None))
    )
    product = result.scalar_one_or_none()
    if not product:
        raise HTTPException(status_code=404, detail="Product not found")
    return product


async def related_products(
    db: AsyncSession,
    product_id: uuid.UUID,
    *,
    limit: int = 12,
) -> dict[str, list[Product]]:
    """Discover more: same shop, same category, then popular elsewhere."""
    seed = await get_product(db, product_id)
    limit = min(max(limit, 4), 24)
    has_image = Product.id.in_(
        select(ProductImage.product_id).where(
            ProductImage.url.is_not(None),
            ProductImage.url != "",
        )
    )
    base = [
        Product.deleted_at.is_(None),
        Product.is_active.is_(True),
        Product.id != seed.id,
        has_image,
    ]

    same_shop = list(
        (
            await db.execute(
                select(Product)
                .options(selectinload(Product.images))
                .where(*base, Product.business_id == seed.business_id)
                .order_by(Product.created_at.desc())
                .limit(limit)
            )
        ).scalars().all()
    )

    same_category: list[Product] = []
    if seed.category_id is not None:
        same_category = list(
            (
                await db.execute(
                    select(Product)
                    .options(selectinload(Product.images))
                    .where(
                        *base,
                        Product.category_id == seed.category_id,
                        Product.business_id != seed.business_id,
                    )
                    .order_by(Product.created_at.desc())
                    .limit(limit)
                )
            ).scalars().all()
        )

    seen = {seed.id, *(p.id for p in same_shop), *(p.id for p in same_category)}
    popular = list(
        (
            await db.execute(
                select(Product)
                .options(selectinload(Product.images))
                .where(*base, Product.id.notin_(list(seen)))
                .order_by(Product.created_at.desc())
                .limit(limit)
            )
        ).scalars().all()
    )

    # Merged “for you” rail: shop first, then category peers, then popular.
    for_you: list[Product] = []
    for bucket in (same_shop, same_category, popular):
        for p in bucket:
            if p.id in {x.id for x in for_you}:
                continue
            for_you.append(p)
            if len(for_you) >= limit:
                break
        if len(for_you) >= limit:
            break

    return {
        "same_shop": same_shop[:limit],
        "same_category": same_category[:limit],
        "popular": popular[:limit],
        "items": for_you,
    }


async def update_product(
    db: AsyncSession, user: User, product_id: uuid.UUID, data: ProductUpdate
) -> Product:
    product = await get_product(db, product_id)
    await assert_business_member(
        db,
        user,
        product.business_id,
        {MemberRole.OWNER.value, MemberRole.MANAGER.value, MemberRole.STAFF.value},
    )
    before_active = bool(product.is_active)
    for field, value in data.model_dump(exclude_unset=True).items():
        setattr(product, field, value)
    product.version += 1
    await db.flush()
    # Deactivating a product must not delete its promo clips — unlink only.
    if before_active and not product.is_active:
        from app.services import discover as discover_service

        await discover_service.on_product_unavailable(db, product.id)
    return await get_product(db, product_id)


def newest_servable_image(images):
    """The photo the shop should show. A later upload replaces the earlier one."""
    from app.core.media_root import servable_media_url

    live = [img for img in images if servable_media_url(getattr(img, "url", None))]
    if not live:
        return None

    def recency(img) -> tuple:
        created = getattr(img, "created_at", None)
        stamp = created.timestamp() if created is not None else 0
        return (stamp, getattr(img, "sort_order", 0) or 0)

    return max(live, key=recency)


def _discard_replaced_files(urls: list[str], *, keep: str) -> None:
    from app.core.media_root import media_file_from_url

    for old in urls:
        if not old or old == keep:
            continue
        path = media_file_from_url(old)
        if path is None:
            continue
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass


async def add_product_image(
    db: AsyncSession, user: User, product_id: uuid.UUID, url: str, object_key: str | None
) -> Product:
    """Store the new photo as the only product image. The edit screen replaces."""
    product = await get_product(db, product_id)
    await assert_business_member(
        db,
        user,
        product.business_id,
        {MemberRole.OWNER.value, MemberRole.MANAGER.value, MemberRole.STAFF.value},
    )
    previous = list(product.images)
    db.add(
        ProductImage(
            product_id=product.id,
            url=url,
            object_key=object_key,
            is_primary=True,
            sort_order=0,
        )
    )
    for image in previous:
        image.is_primary = False
        await db.delete(image)
    await db.flush()
    _discard_replaced_files([img.url for img in previous], keep=url)
    db.expire(product, ["images"])
    return await get_product(db, product_id)


async def search(
    db: AsyncSession,
    *,
    q: str,
    page: int = 1,
    page_size: int = 20,
) -> dict:
    """
    Rank by: text relevance, verification, rating, popularity (review_count).
    Distance ranking can be added once PostGIS is enabled.
    """
    page_size = min(max(page_size, 1), 100)
    like = f"%{q}%"
    relevance = case(
        (Business.name.ilike(like), 3),
        (Business.description.ilike(like), 2),
        else_=1,
    )
    verified_boost = case((Business.verification_status == "VERIFIED", 2), else_=0)
    biz_stmt = (
        select(Business)
        .options(selectinload(Business.location))
        .where(
            Business.deleted_at.is_(None),
            Business.status == "ACTIVE",
            or_(Business.name.ilike(like), Business.description.ilike(like)),
        )
        .order_by((relevance + verified_boost).desc(), Business.rating.desc(), Business.review_count.desc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    )
    businesses = (await db.execute(biz_stmt)).scalars().all()

    prod_stmt = (
        select(Product)
        .options(selectinload(Product.images))
        .where(
            Product.deleted_at.is_(None),
            Product.is_active.is_(True),
            or_(Product.name.ilike(like), Product.description.ilike(like)),
        )
        .order_by(Product.created_at.desc())
        .limit(page_size)
    )
    products = (await db.execute(prod_stmt)).scalars().all()
    return {"query": q, "businesses": businesses, "products": products}
