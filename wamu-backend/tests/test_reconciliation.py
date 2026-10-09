"""Payment reconciliation unit tests."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import uuid4
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base
from app.integrations.payments.provider import PaymentInitResult
from app.models.audit import AuditLog  # noqa: F401 — register metadata
from app.models.business import Business, BusinessStatus, Category, VerificationStatus
from app.models.notification import Notification  # noqa: F401
from app.models.order import Order, OrderStatus
from app.models.payment import Payment, PaymentStatus
from app.models.user import User, UserRole
from app.services.reconciliation import reconcile_pending_payments

TEST_DB = "sqlite+aiosqlite:///:memory:"


@pytest_asyncio.fixture
async def db():
    engine = create_async_engine(TEST_DB, future=True)
    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    async with session_factory() as session:
        yield session
    await engine.dispose()


async def _seed_pending_payment(
    db: AsyncSession, *, with_reference: bool = False
) -> Payment:
    cat = Category(name="R", slug=f"r-{uuid4().hex[:6]}")
    db.add(cat)
    await db.flush()
    owner = User(phone=f"+2567{uuid4().hex[:8]}", phone_verified=True, role=UserRole.BUSINESS.value)
    customer = User(
        phone=f"+2567{uuid4().hex[:8]}", phone_verified=True, role=UserRole.CUSTOMER.value
    )
    db.add_all([owner, customer])
    await db.flush()
    biz = Business(
        owner_id=owner.id,
        name="Shop",
        slug=f"shop-{uuid4().hex[:6]}",
        category_id=cat.id,
        status=BusinessStatus.ACTIVE.value,
        verification_status=VerificationStatus.VERIFIED.value,
    )
    db.add(biz)
    await db.flush()
    order = Order(
        customer_id=customer.id,
        business_id=biz.id,
        status=OrderStatus.PENDING.value,
        subtotal=Decimal("1000.00"),
        delivery_fee=Decimal("0"),
        total=Decimal("1000.00"),
        currency="UGX",
        fulfillment="PICKUP",
    )
    db.add(order)
    await db.flush()
    payment = Payment(
        order_id=order.id,
        user_id=customer.id,
        amount=Decimal("1000.00"),
        currency="UGX",
        provider="MTN",
        provider_reference=f"MTN-ref-{uuid4().hex[:8]}" if with_reference else None,
        idempotency_key=f"idem-{uuid4().hex}",
        status=PaymentStatus.PENDING.value,
        phone=customer.phone,
    )
    db.add(payment)
    await db.flush()
    return payment


@pytest.mark.asyncio
async def test_reconcile_expires_stale_pending(db: AsyncSession):
    stale = await _seed_pending_payment(db, with_reference=False)
    stale.created_at = datetime.now(timezone.utc) - timedelta(hours=48)
    await db.flush()

    summary = await reconcile_pending_payments(db, stale_hours=24, limit=10)
    await db.commit()
    await db.refresh(stale)
    assert summary["expired"] >= 1
    assert stale.status == PaymentStatus.FAILED.value
    assert (stale.raw_response or {}).get("reconcile_expired") is True


@pytest.mark.asyncio
async def test_reconcile_provider_success_confirms_order(db: AsyncSession):
    payment = await _seed_pending_payment(db, with_reference=True)
    mock_result = PaymentInitResult(
        provider_reference=payment.provider_reference or "x",
        status="SUCCESS",
        raw={"polled": True},
    )
    with patch(
        "app.services.reconciliation.get_payment_provider"
    ) as get_provider:
        adapter = AsyncMock()
        adapter.check_status = AsyncMock(return_value=mock_result)
        get_provider.return_value = adapter
        summary = await reconcile_pending_payments(db, stale_hours=24, limit=10)
        await db.commit()

    await db.refresh(payment)
    assert summary["updated"] >= 1
    assert payment.status == PaymentStatus.SUCCESS.value
    order = await db.get(Order, payment.order_id)
    assert order is not None
    assert order.status == OrderStatus.CONFIRMED.value
