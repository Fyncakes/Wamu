"""Passenger rides (Phase 5 thin MVP) — request, assign, advance FSM."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.core.security import hash_token
from app.main import app
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
            for phone in ("+256755500001", "+256755500002", "+256700000001"):
                session.add(
                    OtpChallenge(
                        phone=phone,
                        code_hash=hash_token("123456"),
                        expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
                    )
                )
            customer = User(
                phone="+256755500001", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            rider_user = User(
                phone="+256755500002", phone_verified=True, role=UserRole.CUSTOMER.value
            )
            admin = User(
                phone="+256700000001", phone_verified=True, role=UserRole.ADMIN.value
            )
            session.add_all([customer, rider_user, admin])
            await session.flush()
            session.add(UserProfile(user_id=customer.id, first_name="Cust"))
            session.add(UserProfile(user_id=rider_user.id, first_name="Rider"))
            session.add(UserProfile(user_id=admin.id, first_name="Admin"))
            await session.commit()
            yield {
                "client": ac,
                "customer_phone": "+256755500001",
                "rider_phone": "+256755500002",
                "admin_phone": "+256700000001",
                "session_factory": session_factory,
            }

    app.dependency_overrides.clear()
    await engine.dispose()


async def _token(env, phone: str) -> str:
    sf = env["session_factory"]
    async with sf() as session:
        session.add(
            OtpChallenge(
                phone=phone,
                code_hash=hash_token("123456"),
                expires_at=datetime.now(timezone.utc) + timedelta(minutes=10),
            )
        )
        await session.commit()
    r = await env["client"].post(
        "/api/v1/auth/verify-otp", json={"phone": phone, "code": "123456"}
    )
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


@pytest.mark.asyncio
async def test_request_assign_advance_complete(env):
    client = env["client"]
    rider_h = {"Authorization": f"Bearer {await _token(env, env['rider_phone'])}"}
    cust_h = {"Authorization": f"Bearer {await _token(env, env['customer_phone'])}"}

    enroll = await client.post(
        "/api/v1/riders/me",
        headers=rider_h,
        json={"display_name": "Boda Pilot", "vehicle_type": "BODA"},
    )
    assert enroll.status_code == 201, enroll.text
    assert enroll.json()["status"] == "DRAFT"
    admin_h = {"Authorization": f"Bearer {await _token(env, env['admin_phone'])}"}
    approve = await client.post(
        f"/api/v1/admin/riders/{enroll.json()['id']}/approve",
        headers=admin_h,
        json={"note": "test approve"},
    )
    assert approve.status_code == 200, approve.text

    ride = await client.post(
        "/api/v1/rides",
        headers=cust_h,
        json={
            "pickup_address": "Ntinda market gate",
            "dropoff_address": "Nakawa trading centre",
        },
    )
    assert ride.status_code == 201, ride.text
    body = ride.json()
    assert body["status"] == "ACCEPTED"
    assert body["rider"] is not None
    assert float(body["fare"]) >= 8000
    ride_id = body["id"]

    mine = await client.get("/api/v1/rides", headers=cust_h)
    assert mine.status_code == 200
    assert any(r["id"] == ride_id for r in mine.json())

    transit = await client.patch(
        f"/api/v1/rides/{ride_id}",
        headers=rider_h,
        json={"status": "IN_TRANSIT"},
    )
    assert transit.status_code == 200, transit.text
    assert transit.json()["status"] == "IN_TRANSIT"

    done = await client.patch(
        f"/api/v1/rides/{ride_id}",
        headers=rider_h,
        json={"status": "COMPLETED"},
    )
    assert done.status_code == 200, done.text
    assert done.json()["status"] == "COMPLETED"
