"""Merchant KYC — register → docs → AI signals → admin decision + policy defaults."""

from __future__ import annotations

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.core.security import create_access_token
from app.main import app
from app.models.user import User, UserProfile, UserRole

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

    async with session_factory() as session:
        admin = User(phone="+256700000001", phone_verified=True, role=UserRole.ADMIN.value)
        owner = User(phone="+256700000055", phone_verified=True, role=UserRole.CUSTOMER.value)
        session.add_all([admin, owner])
        await session.flush()
        session.add(UserProfile(user_id=admin.id, first_name="Admin", last_name="Wamu"))
        session.add(UserProfile(user_id=owner.id, first_name="Grace", last_name="Nakato"))
        await session.commit()
        admin_id = admin.id
        owner_id = owner.id

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield {
            "client": ac,
            "admin_token": create_access_token(str(admin_id)),
            "owner_token": create_access_token(str(owner_id)),
        }

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_kyc_policy_defaults_off(env):
    client: AsyncClient = env["client"]
    oh = {"Authorization": f"Bearer {env['owner_token']}"}
    r = await client.get("/api/v1/config/kyc", headers=oh)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["merchants"]["enabled"] is False
    assert body["merchants"]["require_verified_for_payout"] is False
    assert body["government_verification"]["status"] == "NOT_CONNECTED"


@pytest.mark.asyncio
async def test_merchant_kyc_full_flow(env):
    client: AsyncClient = env["client"]
    oh = {"Authorization": f"Bearer {env['owner_token']}"}
    ah = {"Authorization": f"Bearer {env['admin_token']}"}

    created = await client.post(
        "/api/v1/businesses",
        headers=oh,
        json={"name": "Nakato Foods", "description": "Rolex & juice"},
    )
    assert created.status_code == 201, created.text
    biz = created.json()
    assert biz["verification_status"] == "UNVERIFIED"
    biz_id = biz["id"]

    r = await client.post(
        f"/api/v1/businesses/{biz_id}/kyc/register",
        headers=oh,
        json={
            "owner_full_name": "Grace Nakato",
            "owner_nin": "CF90010112345",
            "owner_date_of_birth": "1990-01-01",
        },
    )
    assert r.status_code == 200, r.text
    assert r.json()["owner_nin"].endswith("2345")
    assert r.json()["kyc_status"] == "DRAFT"

    for dtype in (
        "OWNER_ID_FRONT",
        "OWNER_ID_BACK",
        "SELFIE",
        "BUSINESS_PREMISES",
    ):
        up = await client.post(
            f"/api/v1/businesses/{biz_id}/kyc/documents",
            headers=oh,
            json={"doc_type": dtype, "url": f"https://cdn.example/{dtype}.jpg"},
        )
        assert up.status_code == 200, up.text

    sub = await client.post(f"/api/v1/businesses/{biz_id}/kyc/submit", headers=oh)
    assert sub.status_code == 200, sub.text
    assert sub.json()["kyc_status"] == "UNDER_REVIEW"
    assert sub.json()["verification_status"] == "PENDING"
    assert sub.json()["ai_result"] in {"PASS", "REVIEW", "FAIL"}

    q = await client.get("/api/v1/admin/businesses/kyc-queue?status=QUEUE", headers=ah)
    assert q.status_code == 200, q.text
    items = q.json().get("items") or q.json()
    assert any(i["id"] == biz_id for i in items)

    detail = await client.get(f"/api/v1/admin/businesses/{biz_id}/kyc", headers=ah)
    assert detail.status_code == 200, detail.text
    assert detail.json()["owner_nin"] == "CF90010112345"

    appr = await client.post(
        f"/api/v1/admin/businesses/{biz_id}/kyc/approve",
        headers=ah,
        json={"note": "Docs look good"},
    )
    assert appr.status_code == 200, appr.text
    assert appr.json()["kyc_status"] == "APPROVED"
    assert appr.json()["verification_status"] == "VERIFIED"

    mine = await client.get(f"/api/v1/businesses/{biz_id}/kyc", headers=oh)
    assert mine.status_code == 200
    assert mine.json()["kyc_status"] == "APPROVED"


@pytest.mark.asyncio
async def test_admin_can_enable_merchant_kyc_policy(env):
    client: AsyncClient = env["client"]
    ah = {"Authorization": f"Bearer {env['admin_token']}"}
    r = await client.put(
        "/api/v1/admin/settings/kyc",
        headers=ah,
        json={
            "merchants": {
                "enabled": True,
                "require_verified_for_payout": True,
            }
        },
    )
    assert r.status_code == 200, r.text
    assert r.json()["merchants"]["enabled"] is True
    assert r.json()["merchants"]["require_verified_for_payout"] is True
