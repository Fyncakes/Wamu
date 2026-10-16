"""Direct unit tests for ledger service helpers (coverage)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import uuid4

import pytest
import pytest_asyncio
from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base
from app.models.ledger import LedgerAccountType, LedgerDirection, LedgerEntry
from app.models.order import Order, OrderStatus
from app.models.payment import Payment, PaymentStatus
from app.services.commission import compute_for_order
from app.services.ledger import (
    LedgerLeg,
    account_balance_minor,
    list_entries,
    post_group,
    post_payment_confirmed,
    post_refund_reversal,
    sum_account_credits,
    sum_account_debits,
)

TEST_DB = "sqlite+aiosqlite:///:memory:"


@pytest_asyncio.fixture
async def db():
    engine = create_async_engine(TEST_DB, future=True)
    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    async with session_factory() as session:
        yield session
        await session.rollback()
    await engine.dispose()


def _order(**kwargs) -> Order:
    sub = Decimal(kwargs.get("subtotal", "10000"))
    fee = Decimal(kwargs.get("delivery", "2000"))
    return Order(
        id=kwargs.get("id", uuid4()),
        customer_id=uuid4(),
        business_id=kwargs.get("business_id", uuid4()),
        subtotal=sub,
        delivery_fee=fee,
        total=sub + fee,
        currency="UGX",
        fulfillment="DELIVERY",
        status=kwargs.get("status", OrderStatus.CONFIRMED.value),
    )


@pytest.mark.asyncio
async def test_post_group_rejects_unbalanced(db: AsyncSession):
    with pytest.raises(HTTPException) as ei:
        await post_group(
            db,
            legs=[
                LedgerLeg(
                    account_type="a",
                    direction=LedgerDirection.DEBIT.value,
                    amount_minor=100,
                    leg_key="d",
                ),
                LedgerLeg(
                    account_type="b",
                    direction=LedgerDirection.CREDIT.value,
                    amount_minor=50,
                    leg_key="c",
                ),
            ],
            source_type="order",
            source_id=uuid4(),
            idempotency_prefix=f"t:{uuid4()}",
        )
    assert ei.value.status_code == 500


@pytest.mark.asyncio
async def test_post_group_empty_and_zero(db: AsyncSession):
    with pytest.raises(HTTPException):
        await post_group(
            db,
            legs=[],
            source_type="order",
            source_id=uuid4(),
            idempotency_prefix=f"t:{uuid4()}",
        )
    gid = await post_group(
        db,
        legs=[
            LedgerLeg(
                account_type="a",
                direction=LedgerDirection.DEBIT.value,
                amount_minor=0,
                leg_key="z",
            )
        ],
        source_type="order",
        source_id=uuid4(),
        idempotency_prefix=f"t:{uuid4()}",
    )
    assert gid is None


@pytest.mark.asyncio
async def test_post_payment_and_refund_reversal(db: AsyncSession):
    order = _order()
    db.add(order)
    payment = Payment(
        id=uuid4(),
        order_id=order.id,
        user_id=order.customer_id,
        amount=order.total,
        currency="UGX",
        provider="MOCK",
        idempotency_key=f"ik-{uuid4().hex[:8]}",
        status=PaymentStatus.SUCCESS.value,
    )
    db.add(payment)
    await db.flush()

    g1 = await post_payment_confirmed(db, payment, order)
    assert g1 is not None
    g1b = await post_payment_confirmed(db, payment, order)  # idempotent
    assert g1b == g1

    bd = compute_for_order(order)
    bal = await account_balance_minor(
        db, LedgerAccountType.MERCHANT_PAYABLE.value, order.business_id
    )
    assert bal == bd.merchant_net_minor

    order.status = OrderStatus.DELIVERED.value
    g2 = await post_refund_reversal(db, payment, order, reason="admin_refund")
    assert g2 is not None
    # Rider retained after delivery → merchant clawed back, commission reversed
    bal2 = await account_balance_minor(
        db, LedgerAccountType.MERCHANT_PAYABLE.value, order.business_id
    )
    assert bal2 == 0

    credits = await sum_account_credits(
        db, LedgerAccountType.WAMU_COMMISSION.value
    )
    debits = await sum_account_debits(
        db, LedgerAccountType.WAMU_COMMISSION.value
    )
    assert credits == debits == bd.commission_minor


@pytest.mark.asyncio
async def test_refund_before_delivery_reverses_rider(db: AsyncSession):
    order = _order(status=OrderStatus.CONFIRMED.value)
    db.add(order)
    payment = Payment(
        id=uuid4(),
        order_id=order.id,
        user_id=order.customer_id,
        amount=order.total,
        currency="UGX",
        provider="MOCK",
        idempotency_key=f"ik-{uuid4().hex[:8]}",
        status=PaymentStatus.SUCCESS.value,
    )
    db.add(payment)
    await db.flush()
    await post_payment_confirmed(db, payment, order)
    await post_refund_reversal(db, payment, order, reason="cancel")
    rider_bal = await account_balance_minor(
        db, LedgerAccountType.RIDER_PAYABLE.value, all_accounts=True
    )
    assert rider_bal == 0


@pytest.mark.asyncio
async def test_list_entries_filters(db: AsyncSession):
    order = _order()
    db.add(order)
    payment = Payment(
        id=uuid4(),
        order_id=order.id,
        user_id=order.customer_id,
        amount=order.total,
        currency="UGX",
        provider="MOCK",
        idempotency_key=f"ik-{uuid4().hex[:8]}",
        status=PaymentStatus.SUCCESS.value,
    )
    db.add(payment)
    await db.flush()
    await post_payment_confirmed(db, payment, order)

    since = datetime.now(timezone.utc) - timedelta(hours=1)
    until = datetime.now(timezone.utc) + timedelta(hours=1)
    rows, total = await list_entries(
        db,
        account_type=LedgerAccountType.MERCHANT_PAYABLE.value,
        account_id=order.business_id,
        source_type="order",
        since=since,
        until=until,
        page=1,
        page_size=10,
    )
    assert total >= 1
    assert rows
    assert all(isinstance(r, LedgerEntry) for r in rows)
