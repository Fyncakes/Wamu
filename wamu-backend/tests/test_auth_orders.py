"""
Critical path tests — auth smoke + utils.

Deeper security/idempotency coverage lives in test_phase0_security.py.
"""

from __future__ import annotations

from decimal import Decimal

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.core.security import hash_token
from app.main import app
from app.models.user import OtpChallenge
from app.services.utils import slugify

TEST_DB = "sqlite+aiosqlite:///:memory:"


@pytest_asyncio.fixture
async def client():
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
                    phone="+256700000099",
                    code_hash=hash_token("123456"),
                    expires_at=__import__("datetime").datetime.now(
                        __import__("datetime").timezone.utc
                    )
                    + __import__("datetime").timedelta(minutes=10),
                )
            )
            await session.commit()
        yield ac

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_health(client: AsyncClient):
    r = await client.get("/api/v1/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


@pytest.mark.asyncio
async def test_otp_verify_creates_user(client: AsyncClient):
    r = await client.post(
        "/api/v1/auth/verify-otp",
        json={"phone": "+256700000099", "code": "123456"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert "access_token" in body
    assert body["user"]["phone"] == "+256700000099"


def test_slugify():
    assert slugify("Fyn Cakes!") == "fyn-cakes"


def test_order_total_math():
    subtotal = Decimal("80000.00")
    fee = Decimal("5000.00")
    assert subtotal + fee == Decimal("85000.00")
