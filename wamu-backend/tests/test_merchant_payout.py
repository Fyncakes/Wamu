"""Merchant payout (non-custodial disbursement) tests."""

from __future__ import annotations

from decimal import Decimal
from uuid import uuid4
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base
from app.integrations.payments.provider import PaymentInitResult
from app.models.audit import AuditLog  # noqa: F401
from app.models.business import Business, BusinessStatus, Category, VerificationStatus
from app.models.notification import Notification  # noqa: F401
from app.models.order import Order, OrderStatus
from app.models.payment import Payment, PaymentStatus
from app.models.payout import MerchantPayout, PayoutStatus
from app.models.user import User, UserRole
from app.services.payout import enqueue_payout_for_payment

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


async def _seed_paid_order(db: AsyncSession, *, payout_phone: str | None = "+256700123456"):
    cat = Category(name="R", slug=f"r-{uuid4().hex[:6]}")
    db.add(cat)
    await db.flush()
    owner = User(
        phone=f"+2567{uuid4().hex[:8]}", phone_verified=True, role=UserRole.BUSINESS.value
    )
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
        phone="+256700000099",
        payout_phone=payout_phone,
        payout_provider="MOCK",
        status=BusinessStatus.ACTIVE.value,
        verification_status=VerificationStatus.VERIFIED.value,
    )
    db.add(biz)
    await db.flush()
    order = Order(
        customer_id=customer.id,
        business_id=biz.id,
        status=OrderStatus.CONFIRMED.value,
        subtotal=Decimal("5000.00"),
        delivery_fee=Decimal("0"),
        total=Decimal("5000.00"),
        currency="UGX",
        fulfillment="PICKUP",
    )
    db.add(order)
    await db.flush()
    payment = Payment(
        order_id=order.id,
        user_id=customer.id,
        amount=Decimal("5000.00"),
        currency="UGX",
        provider="MOCK",
        provider_reference=f"MOCK-{uuid4().hex[:8]}",
        idempotency_key=f"idem-{uuid4().hex}",
        status=PaymentStatus.SUCCESS.value,
        phone=customer.phone,
    )
    db.add(payment)
    await db.flush()
    return payment, biz, owner


@pytest.mark.asyncio
async def test_enqueue_payout_on_success(db: AsyncSession):
    payment, biz, _ = await _seed_paid_order(db)
    mock_result = PaymentInitResult(
        provider_reference=f"MOCK-PAYOUT-{uuid4().hex[:8]}",
        status="SUCCESS",
        raw={"mock": True},
    )
    with patch("app.services.payout.get_disbursement_provider") as get_provider:
        adapter = AsyncMock()
        adapter.initiate_disbursement = AsyncMock(return_value=mock_result)
        get_provider.return_value = adapter
        payout = await enqueue_payout_for_payment(db, payment)
        await db.commit()

    assert payout is not None
    assert payout.business_id == biz.id
    assert payout.payee_phone == biz.payout_phone
    assert payout.status == PayoutStatus.SUCCESS.value
    assert payout.amount == Decimal("5000.00")
    assert payout.platform_fee == Decimal("0.00")
    assert payout.fee_bps == 0
    adapter.initiate_disbursement.assert_awaited()
    call_kw = adapter.initiate_disbursement.await_args.kwargs
    assert call_kw["amount"] == Decimal("5000.00")

    again = await enqueue_payout_for_payment(db, payment)
    assert again is not None
    assert again.id == payout.id


@pytest.mark.asyncio
async def test_reverse_payout_on_refund(db: AsyncSession):
    from app.services.payout import reverse_payout_for_payment

    payment, biz, owner = await _seed_paid_order(db)
    mock_result = PaymentInitResult(
        provider_reference=f"MOCK-PAYOUT-{uuid4().hex[:8]}",
        status="SUCCESS",
        raw={"mock": True},
    )
    with patch("app.services.payout.get_disbursement_provider") as get_provider:
        adapter = AsyncMock()
        adapter.initiate_disbursement = AsyncMock(return_value=mock_result)
        get_provider.return_value = adapter
        payout = await enqueue_payout_for_payment(db, payment)
        await db.flush()

    assert payout is not None
    assert payout.status == PayoutStatus.SUCCESS.value

    reversed_p = await reverse_payout_for_payment(db, payment, reason="order_cancelled")
    await db.flush()
    assert reversed_p is not None
    assert reversed_p.status == PayoutStatus.REVERSED.value

    notes = (
        await db.execute(
            select(Notification).where(
                Notification.user_id == owner.id,
                Notification.type == "PAYOUT_REVERSED",
            )
        )
    ).scalars().all()
    assert len(notes) >= 1


@pytest.mark.asyncio
async def test_enqueue_applies_platform_fee_bps(db: AsyncSession):
    payment, biz, _ = await _seed_paid_order(db)
    mock_result = PaymentInitResult(
        provider_reference=f"MOCK-PAYOUT-{uuid4().hex[:8]}",
        status="SUCCESS",
        raw={"mock": True},
    )
    with patch("app.services.payout.get_settings") as mock_get_settings, patch(
        "app.services.payout.get_disbursement_provider"
    ) as get_provider:
        mock_get_settings.return_value.platform_fee_bps = 250  # 2.5%
        adapter = AsyncMock()
        adapter.initiate_disbursement = AsyncMock(return_value=mock_result)
        get_provider.return_value = adapter
        payout = await enqueue_payout_for_payment(db, payment)
        await db.commit()

    assert payout is not None
    assert payout.business_id == biz.id
    assert payout.platform_fee == Decimal("125.00")
    assert payout.amount == Decimal("4875.00")
    assert payout.fee_bps == 250
    call_kw = adapter.initiate_disbursement.await_args.kwargs
    assert call_kw["amount"] == Decimal("4875.00")


@pytest.mark.asyncio
async def test_compute_platform_fee_helpers():
    from app.services.payout import compute_platform_fee

    net, fee, bps = compute_platform_fee(Decimal("5000.00"), fee_bps=0)
    assert (net, fee, bps) == (Decimal("5000.00"), Decimal("0.00"), 0)

    net, fee, bps = compute_platform_fee(Decimal("100.00"), fee_bps=250)
    assert fee == Decimal("2.50")
    assert net == Decimal("97.50")
    assert bps == 250


@pytest.mark.asyncio
async def test_enqueue_skips_without_payee_phone(db: AsyncSession):
    payment, _, _ = await _seed_paid_order(db)
    with patch("app.services.payout.resolve_payee_phone", return_value=None):
        payout = await enqueue_payout_for_payment(db, payment)
        await db.commit()
    assert payout is None
    n = await db.scalar(select(func.count()).select_from(MerchantPayout))
    assert int(n or 0) == 0
