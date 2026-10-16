"""Phase C — execute queue, ledger settlement, live-path gates."""

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
from app.models.ledger import LedgerAccountType, LedgerDirection, LedgerEntry
from app.models.notification import Notification  # noqa: F401
from app.models.order import Order, OrderStatus
from app.models.payment import Payment, PaymentStatus
from app.models.payout import MerchantPayout, PayoutStatus
from app.models.user import User, UserRole
from app.services.payout import enqueue_payout_for_payment, execute_payout, execute_payout_queue

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


async def _seed(db: AsyncSession):
    cat = Category(name="R", slug=f"r-{uuid4().hex[:6]}")
    db.add(cat)
    await db.flush()
    owner = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.BUSINESS.value,
    )
    admin = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.ADMIN.value,
    )
    customer = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.CUSTOMER.value,
    )
    db.add_all([owner, admin, customer])
    await db.flush()
    biz = Business(
        owner_id=owner.id,
        name="Shop",
        slug=f"shop-{uuid4().hex[:6]}",
        category_id=cat.id,
        phone="+256700000099",
        payout_phone="+256700123456",
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
        subtotal=Decimal("10000.00"),
        delivery_fee=Decimal("0"),
        total=Decimal("10000.00"),
        currency="UGX",
        fulfillment="PICKUP",
    )
    db.add(order)
    await db.flush()
    payment = Payment(
        order_id=order.id,
        user_id=customer.id,
        amount=Decimal("10000.00"),
        currency="UGX",
        provider="MOCK",
        provider_reference=f"MOCK-{uuid4().hex[:8]}",
        idempotency_key=f"idem-{uuid4().hex}",
        status=PaymentStatus.SUCCESS.value,
        phone=customer.phone,
    )
    db.add(payment)
    await db.flush()
    return payment, biz, owner, admin


@pytest.mark.asyncio
async def test_execute_queued_payout(db: AsyncSession):
    payment, biz, _, admin = await _seed(db)

    class _S:
        payout_auto_execute = False
        platform_fee_bps = 250

    with patch("app.services.payout.get_settings", return_value=_S()), patch(
        "app.services.payout.get_disbursement_provider"
    ) as get_provider:
        adapter = AsyncMock()
        adapter.initiate_disbursement = AsyncMock(
            return_value=PaymentInitResult(
                provider_reference="Q1", status="SUCCESS", raw={}
            )
        )
        get_provider.return_value = adapter
        queued = await enqueue_payout_for_payment(db, payment)
        await db.flush()
        assert queued is not None
        assert queued.status == PayoutStatus.PENDING.value
        adapter.initiate_disbursement.assert_not_awaited()

        # Admin execute (still patched get_settings but execute bypasses auto gate)
        done = await execute_payout(db, admin, queued.id)
        await db.flush()

    assert done.status == PayoutStatus.SUCCESS.value
    adapter.initiate_disbursement.assert_awaited()

    audit = await db.scalar(
        select(AuditLog).where(AuditLog.action == "PAYOUT_EXECUTED")
    )
    assert audit is not None

    # Ledger settlement posted
    debit = await db.scalar(
        select(func.count())
        .select_from(LedgerEntry)
        .where(
            LedgerEntry.account_type == LedgerAccountType.MERCHANT_PAYABLE.value,
            LedgerEntry.direction == LedgerDirection.DEBIT.value,
            LedgerEntry.account_id == biz.id,
        )
    )
    assert int(debit or 0) >= 1


@pytest.mark.asyncio
async def test_execute_queue_batch(db: AsyncSession):
    payment, _, _, admin = await _seed(db)

    class _S:
        payout_auto_execute = False
        platform_fee_bps = 250

    with patch("app.services.payout.get_settings", return_value=_S()), patch(
        "app.services.payout.get_disbursement_provider"
    ) as get_provider:
        adapter = AsyncMock()
        adapter.initiate_disbursement = AsyncMock(
            return_value=PaymentInitResult(
                provider_reference="Q2", status="SUCCESS", raw={}
            )
        )
        get_provider.return_value = adapter
        await enqueue_payout_for_payment(db, payment)
        await db.flush()
        summary = await execute_payout_queue(db, admin, limit=10)
        await db.flush()

    assert summary["executed"] >= 1
    assert summary["success"] >= 1


@pytest.mark.asyncio
async def test_settlement_idempotent_on_duplicate_success_notify(db: AsyncSession):
    payment, biz, _, admin = await _seed(db)

    class _S:
        payout_auto_execute = True
        platform_fee_bps = 250

    with patch("app.services.payout.get_settings", return_value=_S()), patch(
        "app.services.payout.get_disbursement_provider"
    ) as get_provider:
        adapter = AsyncMock()
        adapter.initiate_disbursement = AsyncMock(
            return_value=PaymentInitResult(
                provider_reference="S1", status="SUCCESS", raw={}
            )
        )
        get_provider.return_value = adapter
        payout = await enqueue_payout_for_payment(db, payment)
        await db.flush()

    assert payout is not None
    assert payout.status == PayoutStatus.SUCCESS.value

    from app.services.ledger import post_payout_settled

    # Second settle is idempotent
    again = await post_payout_settled(db, payout, created_by="test")
    await db.flush()
    n = await db.scalar(
        select(func.count())
        .select_from(LedgerEntry)
        .where(
            LedgerEntry.source_type == "payout",
            LedgerEntry.account_id == biz.id,
            LedgerEntry.direction == LedgerDirection.DEBIT.value,
        )
    )
    # One settle group = one merchant debit leg
    assert int(n or 0) == 1
    assert again is not None
