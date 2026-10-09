"""Rails readiness + MOCK collection→payout dry-run (no MoMo keys required)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import Settings
from app.core.database import Base, get_db
from app.core.security import hash_token
from app.main import app
from app.models.business import (
    Business,
    BusinessMember,
    BusinessStatus,
    Category,
    MemberRole,
    VerificationStatus,
)
from app.models.product import Product
from app.models.user import OtpChallenge, User, UserProfile, UserRole
from app.services.staging_readiness import rails_readiness

TEST_DB = "sqlite+aiosqlite:///:memory:"


@pytest.fixture
def readiness_mock_only():
    return rails_readiness(
        Settings.model_construct(
            environment="development",
            payment_mock_auto_success=True,
            payment_webhook_secret="dev-webhook-secret-change-me",
            platform_fee_bps=0,
            mtn_subscription_key="",
            mtn_api_user="",
            mtn_api_key="",
            airtel_client_id="",
            airtel_client_secret="",
            turn_urls="",
            turn_username="",
            turn_credential="",
            fcm_server_key="",
            stun_urls="stun:stun.l.google.com:19302",
        )
    )


def test_rails_readiness_mock_dry_run(readiness_mock_only):
    r = readiness_mock_only
    assert r["ready_for_mock_dry_run"] is True
    assert r["ready_for_momo_sandbox"] is False
    assert r["ready_for_carrier_calls"] is False
    assert r["mtn_collections_configured"] is False
    assert r["ice_includes_turn"] is False


def test_rails_readiness_momo_sandbox_flags():
    r = rails_readiness(
        Settings.model_construct(
            environment="staging",
            payment_mock_auto_success=False,
            payment_webhook_secret="staging-webhook-secret-change-me-now",
            platform_fee_bps=0,
            mtn_subscription_key="sub",
            mtn_api_user="user",
            mtn_api_key="key",
            airtel_client_id="",
            airtel_client_secret="",
            turn_urls="turn:10.0.0.5:3478",
            turn_username="wamu",
            turn_credential="secret",
            fcm_server_key="AAAA",
            stun_urls="stun:stun.l.google.com:19302",
        )
    )
    assert r["mtn_collections_configured"] is True
    assert r["ready_for_momo_sandbox"] is True
    assert r["turn_configured"] is True
    assert r["ice_includes_turn"] is True
    assert r["turn_urls_look_local"] is False
    assert r["ready_for_carrier_calls"] is True
    assert r["fcm_server_key_set"] is True


def test_rails_readiness_rejects_loopback_turn():
    r = rails_readiness(
        Settings.model_construct(
            environment="staging",
            payment_mock_auto_success=False,
            payment_webhook_secret="staging-webhook-secret-change-me-now",
            platform_fee_bps=0,
            mtn_subscription_key="",
            mtn_api_user="",
            mtn_api_key="",
            airtel_client_id="",
            airtel_client_secret="",
            turn_urls="turn:127.0.0.1:3478?transport=udp",
            turn_username="wamu",
            turn_credential="secret",
            fcm_server_key="",
            stun_urls="stun:stun.l.google.com:19302",
        )
    )
    assert r["turn_configured"] is True
    assert r["ice_includes_turn"] is True
    assert r["turn_urls_look_local"] is True
    assert r["ready_for_carrier_calls"] is False


@pytest_asyncio.fixture
async def dry_run_env():
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
            session.add(
                OtpChallenge(
                    phone="+256700000088",
                    code_hash=hash_token("123456"),
                    expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                )
            )
            session.add(
                OtpChallenge(
                    phone="+256700000077",
                    code_hash=hash_token("123456"),
                    expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                )
            )
            cat = Category(name="Test", slug=f"test-{uuid4().hex[:6]}", description="t")
            session.add(cat)
            await session.flush()

            owner = User(
                phone="+256700000077",
                phone_verified=True,
                role=UserRole.BUSINESS.value,
            )
            session.add(owner)
            await session.flush()
            session.add(UserProfile(user_id=owner.id, first_name="Owner", last_name="Biz"))

            biz = Business(
                owner_id=owner.id,
                name="Dry Run Grill",
                slug=f"dry-run-{uuid4().hex[:6]}",
                category_id=cat.id,
                phone="+256700000077",
                payout_phone="+256700111222",
                payout_provider="MOCK",
                status=BusinessStatus.ACTIVE.value,
                verification_status=VerificationStatus.VERIFIED.value,
            )
            session.add(biz)
            await session.flush()
            session.add(
                BusinessMember(
                    business_id=biz.id,
                    user_id=owner.id,
                    role=MemberRole.OWNER.value,
                )
            )

            product = Product(
                business_id=biz.id,
                name="Rolex",
                slug=f"rolex-{uuid4().hex[:6]}",
                price=Decimal("8000.00"),
                currency="UGX",
                stock_quantity=10,
                is_active=True,
            )
            session.add(product)
            await session.commit()

            product_id = str(product.id)
            business_id = str(biz.id)

        cust = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000088", "code": "123456"},
        )
        assert cust.status_code == 200, cust.text
        owner_login = await ac.post(
            "/api/v1/auth/verify-otp",
            json={"phone": "+256700000077", "code": "123456"},
        )
        assert owner_login.status_code == 200, owner_login.text

        yield {
            "client": ac,
            "customer_headers": {"Authorization": f"Bearer {cust.json()['access_token']}"},
            "owner_headers": {
                "Authorization": f"Bearer {owner_login.json()['access_token']}"
            },
            "product_id": product_id,
            "business_id": business_id,
        }

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_mock_collection_to_payout_dry_run(dry_run_env):
    client = dry_run_env["client"]
    headers = dry_run_env["customer_headers"]
    owner_headers = dry_run_env["owner_headers"]
    business_id = dry_run_env["business_id"]

    rails = await client.get("/api/v1/health/rails")
    assert rails.status_code == 200
    assert rails.json()["ready_for_mock_dry_run"] is True

    order = await client.post(
        "/api/v1/orders",
        headers=headers,
        json={
            "business_id": business_id,
            "items": [{"product_id": dry_run_env["product_id"], "quantity": 1}],
            "fulfillment": "PICKUP",
        },
    )
    assert order.status_code == 201, order.text
    order_id = order.json()["id"]

    pay = await client.post(
        "/api/v1/payments",
        headers=headers,
        json={
            "order_id": order_id,
            "provider": "MOCK",
            "phone": "+256700000088",
            "idempotency_key": f"dry-{uuid4().hex}",
        },
    )
    assert pay.status_code == 201, pay.text
    assert pay.json()["status"] == "SUCCESS"

    detail = await client.get(f"/api/v1/orders/{order_id}", headers=headers)
    assert detail.status_code == 200
    assert detail.json()["payment_status"] == "SUCCESS"
    assert detail.json()["payment_provider"] == "MOCK"

    payouts = await client.get(
        f"/api/v1/businesses/{business_id}/payouts",
        headers=owner_headers,
    )
    assert payouts.status_code == 200, payouts.text
    rows = payouts.json()
    assert len(rows) >= 1
    assert rows[0]["status"] == "SUCCESS"
    assert rows[0]["order_id"] == order_id
    assert rows[0]["payee_phone"] == "+256700111222"
    assert Decimal(str(rows[0]["amount"])) == Decimal("8000.00")


@pytest.mark.asyncio
async def test_merchant_cannot_advance_unpaid_order(dry_run_env):
    client = dry_run_env["client"]
    headers = dry_run_env["customer_headers"]
    owner_headers = dry_run_env["owner_headers"]
    business_id = dry_run_env["business_id"]

    order = await client.post(
        "/api/v1/orders",
        headers=headers,
        json={
            "business_id": business_id,
            "items": [{"product_id": dry_run_env["product_id"], "quantity": 1}],
            "fulfillment": "PICKUP",
        },
    )
    assert order.status_code == 201, order.text
    order_id = order.json()["id"]
    assert order.json().get("payment_status") is None

    blocked = await client.patch(
        f"/api/v1/orders/{order_id}/status",
        headers=owner_headers,
        json={"status": "CONFIRMED"},
    )
    assert blocked.status_code == 400, blocked.text
    assert "not paid" in blocked.json()["detail"].lower()


@pytest.mark.asyncio
async def test_merchant_can_advance_after_paid(dry_run_env):
    client = dry_run_env["client"]
    headers = dry_run_env["customer_headers"]
    owner_headers = dry_run_env["owner_headers"]
    business_id = dry_run_env["business_id"]

    order = await client.post(
        "/api/v1/orders",
        headers=headers,
        json={
            "business_id": business_id,
            "items": [{"product_id": dry_run_env["product_id"], "quantity": 1}],
            "fulfillment": "PICKUP",
        },
    )
    order_id = order.json()["id"]
    pay = await client.post(
        "/api/v1/payments",
        headers=headers,
        json={
            "order_id": order_id,
            "provider": "MOCK",
            "phone": "+256700000088",
            "idempotency_key": f"adv-{uuid4().hex}",
        },
    )
    assert pay.status_code == 201, pay.text
    # MOCK auto-success also bumps order → CONFIRMED
    detail = await client.get(f"/api/v1/orders/{order_id}", headers=headers)
    assert detail.json()["status"] == "CONFIRMED"
    assert detail.json()["payment_status"] == "SUCCESS"

    advanced = await client.patch(
        f"/api/v1/orders/{order_id}/status",
        headers=owner_headers,
        json={"status": "PROCESSING"},
    )
    assert advanced.status_code == 200, advanced.text
    assert advanced.json()["status"] == "PROCESSING"
    assert advanced.json()["payment_status"] == "SUCCESS"
