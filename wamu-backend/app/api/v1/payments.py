from uuid import UUID

from fastapi import APIRouter, Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.core.webhook_security import require_valid_webhook
from app.models.user import User
from app.schemas.commerce import PaymentCreate, PaymentResponse, WebhookPayload
from app.services import payment as payment_service

router = APIRouter()


@router.post("", response_model=PaymentResponse, status_code=201)
async def create_payment(
    body: PaymentCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await payment_service.initiate_payment(db, user, body)


@router.get("/{payment_id}", response_model=PaymentResponse)
async def get_payment(
    payment_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await payment_service.get_payment(db, payment_id, user)


@router.post("/{payment_id}/refresh", response_model=PaymentResponse)
async def refresh_payment(
    payment_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Poll MoMo provider for PENDING/PROCESSING payments (client await loop)."""
    return await payment_service.refresh_payment(db, payment_id, user)


@router.post("/webhooks/{provider}")
async def webhook(
    provider: str,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """
    Provider callbacks. Signatures:
    - MOCK: `X-Wamu-Signature: sha256=<hmac>`
    - MTN: `X-MTN-Signature` or `X-Callback-Signature`
    - AIRTEL: `X-Airtel-Signature`

    Never trust a client `payment.success` flag — status comes only from verified
    webhooks or the payment provider adapter response.
    """
    data = await require_valid_webhook(request, provider=provider)
    body = WebhookPayload.model_validate(data)
    return await payment_service.process_webhook(db, provider.upper(), body)
