"""Phase B — statement matching, suspense, payout queue gate."""

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
from app.models.ledger import LedgerAccountType, LedgerEntry  # noqa: F401
from app.models.notification import Notification  # noqa: F401
from app.models.order import Order, OrderStatus
from app.models.payment import Payment, PaymentStatus
from app.models.payout import MerchantPayout, PayoutStatus
from app.models.reconciliation import SuspenseItem, SuspenseStatus
from app.models.user import User, UserRole
from app.services.payout import enqueue_payout_for_payment
from app.services.statement_reconciliation import (
    import_statement_lines,
    list_payout_queue,
    match_batch,
    resolve_suspense,
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


async def _seed_payment(
    db: AsyncSession,
    *,
    amount: Decimal = Decimal("5000.00"),
    provider_ref: str | None = None,
) -> Payment:
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
    db.add_all([owner, customer])
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
        subtotal=amount,
        delivery_fee=Decimal("0"),
        total=amount,
        currency="UGX",
        fulfillment="PICKUP",
    )
    db.add(order)
    await db.flush()
    ref = provider_ref or f"MTN-{uuid4().hex[:10]}"
    payment = Payment(
        order_id=order.id,
        user_id=customer.id,
        amount=amount,
        currency="UGX",
        provider="MTN",
        provider_reference=ref,
        idempotency_key=f"idem-{uuid4().hex}",
        status=PaymentStatus.SUCCESS.value,
        phone=customer.phone,
    )
    db.add(payment)
    await db.flush()
    return payment


@pytest.mark.asyncio
async def test_match_known_payment(db: AsyncSession):
    payment = await _seed_payment(db)
    batch = await import_statement_lines(
        db,
        provider="MTN",
        lines=[
            {
                "external_ref": payment.provider_reference,
                "amount_minor": 5000,
                "currency": "UGX",
            }
        ],
        created_by="test",
    )
    run = await match_batch(db, batch, created_by="test")
    await db.flush()

    assert run.matched == 1
    assert run.unmatched == 0
    assert run.suspense == 0
    suspense_n = await db.scalar(select(func.count()).select_from(SuspenseItem))
    assert int(suspense_n or 0) == 0


@pytest.mark.asyncio
async def test_unmatched_goes_to_suspense(db: AsyncSession):
    batch = await import_statement_lines(
        db,
        provider="MTN",
        lines=[
            {
                "external_ref": "ORPHAN-XYZ",
                "amount_minor": 7500,
                "currency": "UGX",
            }
        ],
        created_by="test",
    )
    run = await match_batch(db, batch, created_by="test")
    await db.flush()

    assert run.matched == 0
    assert run.suspense == 1
    item = await db.scalar(select(SuspenseItem))
    assert item is not None
    assert item.status == SuspenseStatus.OPEN.value
    assert item.amount_minor == 7500

    # Ledger parking posted
    n = await db.scalar(
        select(func.count())
        .select_from(LedgerEntry)
        .where(LedgerEntry.account_type == LedgerAccountType.SUSPENSE.value)
    )
    assert int(n or 0) >= 1


@pytest.mark.asyncio
async def test_amount_mismatch_suspense(db: AsyncSession):
    payment = await _seed_payment(db, amount=Decimal("5000.00"))
    batch = await import_statement_lines(
        db,
        provider="MTN",
        lines=[
            {
                "external_ref": payment.provider_reference,
                "amount_minor": 4990,  # mismatch
                "currency": "UGX",
            }
        ],
        created_by="test",
    )
    run = await match_batch(db, batch, created_by="test")
    await db.flush()
    assert run.suspense == 1
    assert run.matched == 0


@pytest.mark.asyncio
async def test_resolve_suspense_write_off(db: AsyncSession):
    batch = await import_statement_lines(
        db,
        provider="MTN",
        lines=[{"external_ref": "ORPHAN-1", "amount_minor": 1000}],
        created_by="test",
    )
    await match_batch(db, batch, created_by="test")
    item = await db.scalar(select(SuspenseItem))
    assert item is not None

    admin = User(
        phone=f"+2567{uuid4().hex[:8]}",
        phone_verified=True,
        role=UserRole.ADMIN.value,
    )
    db.add(admin)
    await db.flush()

    resolved = await resolve_suspense(
        db, admin, item.id, notes="manual write-off after review", action="write_off"
    )
    await db.flush()
    assert resolved.status == SuspenseStatus.RESOLVED.value
    assert resolved.resolution_notes is not None

    audit = await db.scalar(
        select(AuditLog).where(AuditLog.action == "SUSPENSE_RESOLVED")
    )
    assert audit is not None


@pytest.mark.asyncio
async def test_payout_queued_when_auto_execute_off(db: AsyncSession):
    payment = await _seed_payment(db)

    class _S:
        payout_auto_execute = False
        platform_fee_bps = 250

    with patch("app.services.payout.get_settings", return_value=_S()), patch(
        "app.services.payout.get_disbursement_provider"
    ) as get_provider:
        adapter = AsyncMock()
        adapter.initiate_disbursement = AsyncMock(
            return_value=PaymentInitResult(
                provider_reference="X", status="SUCCESS", raw={}
            )
        )
        get_provider.return_value = adapter
        payout = await enqueue_payout_for_payment(db, payment)
        await db.flush()

    assert payout is not None
    assert payout.status == PayoutStatus.PENDING.value
    assert (payout.raw_response or {}).get("queued") is True
    adapter.initiate_disbursement.assert_not_awaited()

    rows, total = await list_payout_queue(db)
    assert total == 1
    assert rows[0].id == payout.id

    queued_audit = await db.scalar(
        select(AuditLog).where(AuditLog.action == "PAYOUT_QUEUED")
    )
    assert queued_audit is not None


@pytest.mark.asyncio
async def test_failed_payout_notifies_merchant(db: AsyncSession):
    payment = await _seed_payment(db)

    class _S:
        payout_auto_execute = True
        platform_fee_bps = 250

    with patch("app.services.payout.get_settings", return_value=_S()), patch(
        "app.services.payout.get_disbursement_provider"
    ) as get_provider:
        adapter = AsyncMock()
        adapter.initiate_disbursement = AsyncMock(
            return_value=PaymentInitResult(
                provider_reference="FAIL-1", status="FAILED", raw={"err": True}
            )
        )
        get_provider.return_value = adapter
        payout = await enqueue_payout_for_payment(db, payment)
        await db.flush()

    assert payout is not None
    assert payout.status == PayoutStatus.FAILED.value
    notes = (
        await db.execute(
            select(Notification).where(Notification.type == "PAYOUT_FAILED")
        )
    ).scalars().all()
    assert len(notes) >= 1
