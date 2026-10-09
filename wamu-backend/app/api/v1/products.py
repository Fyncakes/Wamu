from uuid import UUID

from fastapi import APIRouter, Depends, File, Query, UploadFile
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.integrations.storage import s3
from app.models.user import User
from app.schemas.marketplace import ProductCreate, ProductResponse, ProductUpdate
from app.services import product as product_service

router = APIRouter()


@router.get("", response_model=list[ProductResponse])
async def list_products(
    business_id: UUID | None = None,
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
):
    rows, _ = await product_service.list_products(
        db, business_id=business_id, page=page, page_size=page_size
    )
    return rows


@router.post("/business/{business_id}", response_model=ProductResponse, status_code=201)
async def create_product(
    business_id: UUID,
    body: ProductCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await product_service.create_product(db, user, business_id, body)


@router.get("/business/{business_id}/manage", response_model=list[ProductResponse])
async def list_owner_products(
    business_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Merchant product list — includes items still waiting for a photo."""
    return await product_service.list_owner_products(db, user, business_id)


@router.get("/{product_id}", response_model=ProductResponse)
async def get_product(product_id: UUID, db: AsyncSession = Depends(get_db)):
    return await product_service.get_product(db, product_id)


@router.get("/{product_id}/related")
async def related_products(
    product_id: UUID,
    limit: int = Query(12, ge=4, le=24),
    db: AsyncSession = Depends(get_db),
):
    """Similar / recommended products for the product detail page."""
    buckets = await product_service.related_products(db, product_id, limit=limit)

    def _ser(rows):
        return [ProductResponse.model_validate(p) for p in rows]

    return {
        "same_shop": _ser(buckets["same_shop"]),
        "same_category": _ser(buckets["same_category"]),
        "popular": _ser(buckets["popular"]),
        "items": _ser(buckets["items"]),
    }


@router.patch("/{product_id}", response_model=ProductResponse)
async def update_product(
    product_id: UUID,
    body: ProductUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await product_service.update_product(db, user, product_id, body)


@router.post("/{product_id}/images", response_model=ProductResponse)
async def upload_product_image(
    product_id: UUID,
    file: UploadFile = File(...),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    data = await file.read()
    if len(data) > 8 * 1024 * 1024:
        from fastapi import HTTPException

        raise HTTPException(status_code=400, detail="File too large (max 8MB)")
    content_type = (file.content_type or "application/octet-stream").lower()
    name = (file.filename or "").lower()
    # Flutter web often sends application/octet-stream — sniff from magic bytes / extension.
    if not content_type.startswith("image/"):
        if data[:3] == b"\xff\xd8\xff" or name.endswith((".jpg", ".jpeg")):
            content_type = "image/jpeg"
        elif data[:8] == b"\x89PNG\r\n\x1a\n" or name.endswith(".png"):
            content_type = "image/png"
        elif (data[:4] == b"RIFF" and len(data) >= 12 and data[8:12] == b"WEBP") or name.endswith(
            ".webp"
        ):
            content_type = "image/webp"
        elif data[:6] in (b"GIF87a", b"GIF89a") or name.endswith(".gif"):
            content_type = "image/gif"
        else:
            from fastapi import HTTPException

            raise HTTPException(status_code=400, detail="Only images allowed")
    url, key = s3.upload_bytes(data, content_type=content_type, folder="products")
    return await product_service.add_product_image(db, user, product_id, url, key)
