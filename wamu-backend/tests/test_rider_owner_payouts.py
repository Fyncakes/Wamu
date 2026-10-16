"""Rider delivery-fee payouts + owner commission withdrawal."""

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
from app.models.ledger import (
    LedgerAccountType,
    LedgerDirection,
    LedgerEntry,
    LedgerSourceType,
)
from app.models.notification import Notification  # noqa: F401
from app.models.order import Order, OrderStatus
from app.models.payout import OwnerPayout, PayoutStatus, RiderPayout
from app.models.rider import Delivery, DeliveryStatus, RiderProfile, RiderStatus
from app.models.user import User, UserRole
from app.services.ledger import LedgerLeg, post_group
from app.services.owner_payout import request_owner_payout
from app.services.rider_payout import (
    enqueue_rider_payout_for_delivery,
    update_rider_payout_settings,
)

TEST_DB = "sqlite+aiosqlite:///:memory:"


@pytest_asyncio.fixture
async def db():
    engine = create_async_engine(TEST_DB, future=True)
    session_factory = async_sessionmaker(
        engine, class_=AsyncSession, expire_on_commit=False
    )
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    async with session_factory() as session:
        yield session
    await engine.dispose()


async def _seed_delivery(db: AsyncSession, *, fee: Decimal = Decimal("3000")):
    cat = Category(name="R", slug=f"r-{uuid4().hex[:6]}")
    db.add(cat)
    await db.flush()
    owner = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.BUSINESS.value,
    )
    customer = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.CUSTOMER.value,
    )
    rider_user = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.RIDER.value,
    )
    admin = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.ADMIN.value,
    )
    db.add_all([owner, customer, rider_user, admin])
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
    rider = RiderProfile(
        user_id=rider_user.id,
        display_name="Boda",
        wamu_rider_ref=f"WR-{uuid4().hex[:8]}",
        status=RiderStatus.APPROVED.value,
        payout_phone=rider_user.phone,
        payout_provider="MOCK",
    )
    db.add(rider)
    await db.flush()
    order = Order(
        customer_id=customer.id,
        business_id=biz.id,
        status=OrderStatus.OUT_FOR_DELIVERY.value,
        subtotal=Decimal("10000"),
        delivery_fee=fee,
        total=Decimal("10000") + fee,
        currency="UGX",
        fulfillment="DELIVERY",
    )
    db.add(order)
    await db.flush()
    delivery = Delivery(
        order_id=order.id,
        rider_id=rider.id,
        status=DeliveryStatus.DELIVERED.value,
        fee=fee,
        currency="UGX",
    )
    db.add(delivery)
    await db.flush()
    return delivery, rider, admin


@pytest.mark.asyncio
async def test_rider_payout_queued_when_auto_off(db: AsyncSession):
    delivery, rider, _ = await _seed_delivery(db)

    class _S:
        payout_auto_execute = False
        payment_mock_auto_success = True

    with patch("app.services.rider_payout.get_settings", return_value=_S()), patch(
        "app.services.rider_payout.get_disbursement_provider"
    ) as get_provider:
        adapter = AsyncMock()
        get_provider.return_value = adapter
        payout = await enqueue_rider_payout_for_delivery(db, delivery)
        await db.flush()

    assert payout is not None
    assert payout.rider_id == rider.id
    assert payout.status == PayoutStatus.PENDING.value
    assert payout.amount == Decimal("3000")
    adapter.initiate_disbursement.assert_not_awaited()


@pytest.mark.asyncio
async def test_rider_payout_success_settles_ledger(db: AsyncSession):
    delivery, rider, _ = await _seed_delivery(db)
    # Seed rider_payable credit as payment_confirmed would
    await post_group(
        db,
        legs=[
            LedgerLeg(
                account_type=LedgerAccountType.PROVIDER_CLEARING.value,
                direction=LedgerDirection.DEBIT.value,
                amount_minor=3000,
                leg_key="c",
            ),
            LedgerLeg(
                account_type=LedgerAccountType.RIDER_PAYABLE.value,
                direction=LedgerDirection.CREDIT.value,
                amount_minor=3000,
                account_id=rider.id,
                leg_key="r",
            ),
        ],
        source_type=LedgerSourceType.ORDER.value,
        source_id=delivery.order_id,
        idempotency_prefix=f"test:rider:{delivery.id}",
    )

    class _S:
        payout_auto_execute = True
        payment_mock_auto_success = True

    with patch("app.services.rider_payout.get_settings", return_value=_S()), patch(
        "app.services.rider_payout.get_disbursement_provider"
    ) as get_provider:
        adapter = AsyncMock()
        adapter.initiate_disbursement = AsyncMock(
            return_value=PaymentInitResult(
                provider_reference="RP1", status="SUCCESS", raw={}
            )
        )
        get_provider.return_value = adapter
        payout = await enqueue_rider_payout_for_delivery(db, delivery)
        await db.flush()

    assert payout is not None
    assert payout.status == PayoutStatus.SUCCESS.value
    debit = await db.scalar(
        select(func.count())
        .select_from(LedgerEntry)
        .where(
            LedgerEntry.account_type == LedgerAccountType.RIDER_PAYABLE.value,
            LedgerEntry.direction == LedgerDirection.DEBIT.value,
            LedgerEntry.account_id == rider.id,
        )
    )
    assert int(debit or 0) >= 1


@pytest.mark.asyncio
async def test_rider_payout_settings_update(db: AsyncSession):
    delivery, rider, _ = await _seed_delivery(db)
    user = await db.get(User, rider.user_id)
    assert user is not None
    updated = await update_rider_payout_settings(
        db,
        user,
        payout_phone="+256701111222",
        payout_provider="AIRTEL",
    )
    await db.flush()
    assert updated.payout_phone == "+256701111222"
    assert updated.payout_provider == "AIRTEL"
    assert delivery.id is not None


@pytest.mark.asyncio
async def test_owner_commission_withdraw(db: AsyncSession):
    admin = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.ADMIN.value,
    )
    db.add(admin)
    await db.flush()
    # Seed commission balance
    await post_group(
        db,
        legs=[
            LedgerLeg(
                account_type=LedgerAccountType.PROVIDER_CLEARING.value,
                direction=LedgerDirection.DEBIT.value,
                amount_minor=500,
                leg_key="c",
            ),
            LedgerLeg(
                account_type=LedgerAccountType.WAMU_COMMISSION.value,
                direction=LedgerDirection.CREDIT.value,
                amount_minor=500,
                leg_key="comm",
            ),
        ],
        source_type=LedgerSourceType.ORDER.value,
        source_id=uuid4(),
        idempotency_prefix=f"test:comm:{uuid4().hex[:8]}",
    )

    class _S:
        payout_auto_execute = False
        owner_payout_phone = "+256700999888"
        owner_payout_provider = "MOCK"
        payment_mock_auto_success = True

    with patch("app.services.owner_payout.get_settings", return_value=_S()), patch(
        "app.services.owner_payout.get_disbursement_provider"
    ) as get_provider:
        get_provider.return_value = AsyncMock()
        payout = await request_owner_payout(db, admin, amount_minor=500)
        await db.flush()

    assert payout.status == PayoutStatus.PENDING.value
    assert payout.amount_minor == 500
    assert payout.payee_phone == "+256700999888"
    n = await db.scalar(select(func.count()).select_from(OwnerPayout))
    assert int(n or 0) == 1
