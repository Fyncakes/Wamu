"""Ledger posting, idempotency, refunds, and finance RBAC."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.core.security import hash_token
from app.main import app
from app.models.business import (
    Business,
    BusinessMember,
    Category,
    MemberRole,
    VerificationStatus,
)
from app.models.ledger import LedgerAccountType, LedgerDirection, LedgerEntry
from app.models.product import Product
from app.models.user import OtpChallenge, User, UserProfile, UserRole

TEST_DB = "sqlite+aiosqlite:///:memory:"


@pytest_asyncio.fixture
async def env():
    engine = create_async_engine(TEST_DB, future=True)
    session_factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    async def override_get_db():
        async with session_factory() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    app.dependency_overrides[get_db] = override_get_db
    transport = ASGITransport(app=app)

    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        async with session_factory() as session:
            for phone in ("+256766600001", "+256766600002", "+256766600003"):
                session.add(
                    OtpChallenge(
                        phone=phone,
                        code_hash=hash_token("123456"),
                        expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                    )
                )
            cat = Category(name="Food", slug=f"led-{uuid4().hex[:6]}", description="t")
            session.add(cat)
            await session.flush()
            owner = User(phone="+256766600001", phone_verified=True, role=UserRole.BUSINESS.value)
            session.add(owner)
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="O", last_name="P"))
            other_owner = User(
                phone="+256766600003", phone_verified=True, role=UserRole.BUSINESS.value
            )
            session.add(other_owner)
            await session.flush()
            session.add(UserProfile(user_id=other_owner.id, first_name="X", last_name="Y"))
            customer = User(
                phone="+256766600002", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            session.add(customer)
            await session.flush()
            session.add(UserProfile(user_id=customer.id, first_name="C", last_name="P"))
            biz = Business(
                owner_id=owner.id,
                name="Ledger Kitchen",
                slug=f"led-{uuid4().hex[:6]}",
                category_id=cat.id,
                verification_status=VerificationStatus.VERIFIED.value,
                payout_phone="+256766600001",
                payout_provider="MOCK",
            )
            session.add(biz)
            await session.flush()
            session.add(
                BusinessMember(business_id=biz.id, user_id=owner.id, role=MemberRole.OWNER.value)
            )
            other_biz = Business(
                owner_id=other_owner.id,
                name="Other Shop",
                slug=f"oth-{uuid4().hex[:6]}",
                category_id=cat.id,
                verification_status=VerificationStatus.VERIFIED.value,
                payout_phone="+256766600003",
                payout_provider="MOCK",
            )
            session.add(other_biz)
            await session.flush()
            product = Product(
                business_id=biz.id,
                category_id=cat.id,
                name="Ledger Meal",
                slug=f"meal-{uuid4().hex[:6]}",
                price=Decimal("20000"),
                currency="UGX",
                stock_quantity=10,
            )
            session.add(product)
            product_b = Product(
                business_id=other_biz.id,
                category_id=cat.id,
                name="Other Meal",
                slug=f"meal-{uuid4().hex[:6]}",
                price=Decimal("10000"),
                currency="UGX",
                stock_quantity=10,
            )
            session.add(product_b)
            await session.commit()
            ids = {
                "biz_id": str(biz.id),
                "other_biz_id": str(other_biz.id),
                "product_id": str(product.id),
                "product_b_id": str(product_b.id),
            }

        owner_tok = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256766600001", "code": "123456"},
        )
        other_tok = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256766600003", "code": "123456"},
        )
        cust = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256766600002", "code": "123456"},
        )
        assert cust.status_code == 200
        yield {
            "client": ac,
            "session_factory": session_factory,
            "customer_headers": {"Authorization": f"Bearer {cust.json()['access_token']}"},
            "owner_headers": {
                "Authorization": f"Bearer {owner_tok.json()['access_token']}"
            },
            "other_headers": {
                "Authorization": f"Bearer {other_tok.json()['access_token']}"
            },
            **ids,
        }

    app.dependency_overrides.clear()
    await engine.dispose()


async def _pay_mock(client, ch, order_id: str):
    # MOCK provider still auto-SUCCESS (no MoMo OTP)
    pay = await client.post(
        "/api/v1/payments",
        headers=ch,
        json={
            "order_id": order_id,
            "provider": "MOCK",
            "idempotency_key": f"led-{uuid4().hex[:12]}",
            "phone": "+256766600002",
        },
    )
    assert pay.status_code == 201, pay.text
    body = pay.json()
    assert body["status"] == "SUCCESS"
    return body


@pytest.mark.asyncio
async def test_payment_posts_balanced_ledger(env):
    client = env["client"]
    ch = env["customer_headers"]
    order = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "fulfillment": "PICKUP",
            "items": [{"product_id": env["product_id"], "quantity": 1}],
        },
    )
    assert order.status_code == 201, order.text
    order_id = order.json()["id"]
    await _pay_mock(client, ch, order_id)

    async with env["session_factory"]() as session:
        from uuid import UUID

        oid = UUID(order_id)
        entries = list(
            (
                await session.scalars(
                    select(LedgerEntry).where(LedgerEntry.source_id == oid)
                )
            ).all()
        )
        assert entries, "expected ledger rows"
        debit = sum(
            e.amount_minor for e in entries if e.direction == LedgerDirection.DEBIT.value
        )
        credit = sum(
            e.amount_minor
            for e in entries
            if e.direction == LedgerDirection.CREDIT.value
        )
        assert debit == credit
        # 20000 subtotal @ 2.5% = 500 commission; merchant 19500
        merchant = sum(
            e.amount_minor
            for e in entries
            if e.account_type == LedgerAccountType.MERCHANT_PAYABLE.value
            and e.direction == LedgerDirection.CREDIT.value
        )
        commission = sum(
            e.amount_minor
            for e in entries
            if e.account_type == LedgerAccountType.WAMU_COMMISSION.value
            and e.direction == LedgerDirection.CREDIT.value
        )
        assert merchant == 19500
        assert commission == 500


@pytest.mark.asyncio
async def test_idempotent_double_finalize(env):
    client = env["client"]
    ch = env["customer_headers"]
    order = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "fulfillment": "PICKUP",
            "items": [{"product_id": env["product_id"], "quantity": 1}],
        },
    )
    order_id = order.json()["id"]
    pay = await _pay_mock(client, ch, order_id)
    # Re-post same idempotency key returns existing SUCCESS payment
    again = await client.post(
        "/api/v1/payments",
        headers=ch,
        json={
            "order_id": order_id,
            "provider": "MOCK",
            "idempotency_key": pay.get("idempotency_key")
            or f"dup-{uuid4().hex[:8]}",  # may not echo key
            "phone": "+256766600002",
        },
    )
    # Second create with new key fails because order already paid
    assert again.status_code in {201, 400}

    async with env["session_factory"]() as session:
        from uuid import UUID

        count = await session.scalar(
            select(func.count())
            .select_from(LedgerEntry)
            .where(LedgerEntry.source_id == UUID(order_id))
        )
        # One balanced group only (multiple legs, one group)
        groups = await session.scalars(
            select(LedgerEntry.entry_group_id).where(
                LedgerEntry.source_id == UUID(order_id)
            )
        )
        assert len(set(groups.all())) == 1
        assert count and count >= 2


@pytest.mark.asyncio
async def test_multi_shop_batch_two_ledger_groups(env):
    client = env["client"]
    ch = env["customer_headers"]
    batch = await client.post(
        "/api/v1/orders/batch",
        headers=ch,
        json={
            "fulfillment": "DELIVERY",
            "delivery_address": "Kampala Rd",
            "shops": [
                {
                    "business_id": env["biz_id"],
                    "items": [{"product_id": env["product_id"], "quantity": 1}],
                },
                {
                    "business_id": env["other_biz_id"],
                    "items": [{"product_id": env["product_b_id"], "quantity": 1}],
                },
            ],
        },
    )
    assert batch.status_code == 201, batch.text
    body = batch.json()
    orders = body.get("orders") or []
    assert len(orders) == 2
    # Delivery fee only on first
    fees = [Decimal(str(o["delivery_fee"])) for o in orders]
    assert sum(fees) > 0
    assert min(fees) == 0

    for o in orders:
        await _pay_mock(client, ch, o["id"])

    async with env["session_factory"]() as session:
        from uuid import UUID

        groups = set()
        for o in orders:
            rows = (
                await session.scalars(
                    select(LedgerEntry.entry_group_id).where(
                        LedgerEntry.source_id == UUID(o["id"])
                    )
                )
            ).all()
            groups.update(rows)
        assert len(groups) == 2


@pytest.mark.asyncio
async def test_finance_forbidden_for_other_merchant(env):
    client = env["client"]
    # Owner of other shop cannot read first shop finance
    res = await client.get(
        f"/api/v1/businesses/{env['biz_id']}/finance/summary",
        headers=env["other_headers"],
    )
    assert res.status_code == 403


@pytest.mark.asyncio
async def test_finance_summary_for_owner(env):
    client = env["client"]
    ch = env["customer_headers"]
    order = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "fulfillment": "PICKUP",
            "items": [{"product_id": env["product_id"], "quantity": 1}],
        },
    )
    await _pay_mock(client, ch, order.json()["id"])
    res = await client.get(
        f"/api/v1/businesses/{env['biz_id']}/finance/summary",
        headers=env["owner_headers"],
    )
    assert res.status_code == 200, res.text
    data = res.json()
    assert data["commission_minor"] == 500
    assert data["merchant_net_minor"] == 19500
    assert data["sales_gross_minor"] == 20000


@pytest.mark.asyncio
async def test_merchant_dashboard_kpis(env):
    client = env["client"]
    ch = env["customer_headers"]
    order = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "fulfillment": "PICKUP",
            "items": [{"product_id": env["product_id"], "quantity": 1}],
        },
    )
    assert order.status_code == 201, order.text
    await _pay_mock(client, ch, order.json()["id"])

    res = await client.get(
        f"/api/v1/businesses/{env['biz_id']}/finance/dashboard",
        headers=env["owner_headers"],
        params={"period": "30d"},
    )
    assert res.status_code == 200, res.text
    data = res.json()
    assert data["data_source"] == "live_database"
    assert data["total_sales_minor"] == 20000
    assert data["net_earnings_minor"] == 19500
    assert data["orders_total"] >= 1
    assert isinstance(data["sales_trend"], list)
    assert isinstance(data["attention"], list)
    assert data["business_name"] == "Ledger Kitchen"

    forbidden = await client.get(
        f"/api/v1/businesses/{env['biz_id']}/finance/dashboard",
        headers=env["other_headers"],
    )
    assert forbidden.status_code == 403


@pytest.mark.asyncio
async def test_merchant_report_csv_types(env):
    client = env["client"]
    ch = env["customer_headers"]
    order = await client.post(
        "/api/v1/orders",
        headers=ch,
        json={
            "business_id": env["biz_id"],
            "fulfillment": "PICKUP",
            "items": [{"product_id": env["product_id"], "quantity": 1}],
        },
    )
    await _pay_mock(client, ch, order.json()["id"])

    expected_headers = {
        "sales": "sale_date",
        "orders": "fulfillment",
        "earnings": "gross_sales",
        "payments": "refund_manual",
        "products": "qty_sold",
        "deliveries": "dropoff",
    }
    csv_bodies: dict[str, str] = {}
    for report_type, marker in expected_headers.items():
        res = await client.get(
            f"/api/v1/businesses/{env['biz_id']}/finance/reports",
            headers=env["owner_headers"],
            params={"report_type": report_type, "format": "csv"},
        )
        assert res.status_code == 200, f"{report_type}: {res.text}"
        assert "text/csv" in res.headers.get("content-type", "")
        body = res.text
        assert len(body) > 10
        assert marker in body, f"{report_type} missing {marker}"
        csv_bodies[report_type] = body
        if report_type == "sales":
            assert "SUCCESS" in body
        if report_type == "products":
            assert "Ledger Meal" in body

    # Each report type must be distinct (not copies of earnings).
    unique = set(csv_bodies.values())
    assert len(unique) == len(csv_bodies), "report CSVs must differ by type"

    pdfs: dict[str, bytes] = {}
    for report_type in ("sales", "orders", "earnings", "products"):
        pdf = await client.get(
            f"/api/v1/businesses/{env['biz_id']}/finance/reports",
            headers=env["owner_headers"],
            params={"report_type": report_type, "format": "pdf"},
        )
        assert pdf.status_code == 200, f"{report_type} pdf: {pdf.text}"
        assert pdf.headers.get("content-type", "").startswith("application/pdf")
        assert pdf.content[:4] == b"%PDF"
        assert report_type.encode() in pdf.content
        pdfs[report_type] = pdf.content
    assert len(set(pdfs.values())) == len(pdfs), "report PDFs must differ by type"

    denied = await client.get(
        f"/api/v1/businesses/{env['biz_id']}/finance/reports",
        headers=env["other_headers"],
        params={"report_type": "sales", "format": "csv"},
    )
    assert denied.status_code == 403
