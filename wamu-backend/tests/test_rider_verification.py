"""Rider KYC verification flow — register → docs → AI signals → admin decision."""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from uuid import uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.core.security import create_access_token, hash_token
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

    async with session_factory() as session:
        admin = User(phone="+256700000001", phone_verified=True, role=UserRole.ADMIN.value)
        rider_user = User(phone="+256700000088", phone_verified=True, role=UserRole.CUSTOMER.value)
        session.add_all([admin, rider_user])
        await session.flush()
        session.add(UserProfile(user_id=admin.id, first_name="Admin", last_name="Wamu"))
        session.add(UserProfile(user_id=rider_user.id, first_name="John", last_name="Kato"))
        await session.commit()
        admin_id = admin.id
        rider_uid = rider_user.id

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield {
            "client": ac,
            "admin_token": create_access_token(str(admin_id)),
            "rider_token": create_access_token(str(rider_uid)),
        }

    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.mark.asyncio
async def test_rider_verification_full_flow(env):
    client: AsyncClient = env["client"]
    rh = {"Authorization": f"Bearer {env['rider_token']}"}
    ah = {"Authorization": f"Bearer {env['admin_token']}"}

    # 1. Register personal info
    r = await client.post(
        "/api/v1/riders/me/register",
        headers=rh,
        json={
            "full_name": "John Kato",
            "date_of_birth": "1995-04-12",
            "nin": "CM95041212345",
            "emergency_contact_name": "Mary Kato",
            "emergency_contact_phone": "+256700000077",
            "location_text": "Kampala, Makerere",
            "vehicle_type": "BODA",
            "plate_number": "UBE123A",
        },
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "DRAFT"
    assert body["wamu_rider_ref"].startswith("WAMU-R-")
    assert body["nin"].endswith("2345")
    rider_id = body["id"]

    # 2. Vehicle / licence / insurance fields
    expiry = date.today().replace(year=date.today().year + 2)
    r = await client.patch(
        "/api/v1/riders/me/vehicle-docs",
        headers=rh,
        json={
            "licence_number": "DL-998877",
            "licence_expiry": expiry.isoformat(),
            "licence_class": "A",
            "motorcycle_reg": "UBE123A",
            "motorcycle_ownership": "Owner",
            "insurance_policy": "INS-445566",
            "insurance_reg": "UBE123A",
            "insurance_valid_from": date.today().replace(year=date.today().year - 1).isoformat(),
            "insurance_valid_to": date.today().replace(year=date.today().year + 1).isoformat(),
        },
    )
    assert r.status_code == 200, r.text

    # 3. Upload required documents
    for dtype in (
        "NATIONAL_ID_FRONT",
        "NATIONAL_ID_BACK",
        "LICENCE_FRONT",
        "MOTORCYCLE",
        "INSURANCE",
        "SELFIE",
    ):
        r = await client.post(
            "/api/v1/riders/me/documents",
            headers=rh,
            json={
                "doc_type": dtype,
                "url": f"/media-files/test/{dtype.lower()}.jpg",
                "mime_type": "image/jpeg",
            },
        )
        assert r.status_code == 200, r.text

    ver = r.json()
    assert ver["missing_documents"] == []
    assert ver["can_submit"] is True

    # 4. Submit → AI signals → UNDER_REVIEW (never auto-approve)
    r = await client.post("/api/v1/riders/me/submit-verification", headers=rh)
    assert r.status_code == 200, r.text
    ver = r.json()
    assert ver["status"] == "UNDER_REVIEW"
    assert ver["ai_result"] in {"PASS", "REVIEW", "FAIL"}
    assert "national_id" in (ver.get("ai_checks") or {}).get("checks", {})
    assert ver["government_verification"]["status"] == "NOT_CONNECTED"

    pub = await client.get("/api/v1/riders")
    assert pub.status_code == 200
    assert all(x["id"] != rider_id for x in pub.json())

    # 5. Admin queue
    q = await client.get("/api/v1/admin/riders/verification-queue?status=QUEUE", headers=ah)
    assert q.status_code == 200, q.text
    items = q.json().get("items") or q.json()
    assert any(i["id"] == rider_id for i in items)

    detail = await client.get(f"/api/v1/admin/riders/{rider_id}/verification", headers=ah)
    assert detail.status_code == 200, detail.text
    d = detail.json()
    assert d["nin"] == "CM95041212345"
    assert any(x["doc_type"] == "SELFIE" and x.get("url") for x in d["documents"])

    # 6. Request reupload
    reup = await client.post(
        f"/api/v1/admin/riders/{rider_id}/request-reupload",
        headers=ah,
        json={"note": "Selfie unclear", "reupload_fields": ["SELFIE"]},
    )
    assert reup.status_code == 200, reup.text
    assert reup.json()["status"] == "NEEDS_REUPLOAD"

    r = await client.post(
        "/api/v1/riders/me/documents",
        headers=rh,
        json={"doc_type": "SELFIE", "url": "/media-files/test/selfie2.jpg", "mime_type": "image/jpeg"},
    )
    assert r.status_code == 200, r.text
    r = await client.post("/api/v1/riders/me/submit-verification", headers=rh)
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "UNDER_REVIEW"

    # 7. Approve
    ap = await client.post(
        f"/api/v1/admin/riders/{rider_id}/approve",
        headers=ah,
        json={"note": "Docs look good"},
    )
    assert ap.status_code == 200, ap.text
    assert ap.json()["status"] == "APPROVED"

    ver = await client.get("/api/v1/riders/me/verification", headers=rh)
    assert ver.json()["status"] == "APPROVED"
    assert ver.json()["can_go_online"] is True

    pub = await client.get("/api/v1/riders")
    assert any(x["id"] == rider_id for x in pub.json())
    listed = next(x for x in pub.json() if x["id"] == rider_id)
    assert "nin" not in listed
    assert "documents" not in listed

    # 8. Audit
    logs = await client.get("/api/v1/admin/audit-logs", headers=ah)
    assert logs.status_code == 200, logs.text
    raw = logs.json().get("items") or logs.json()
    actions = [i.get("action") for i in raw if isinstance(i, dict)]
    assert "RIDER_APPROVE" in actions
    assert any(a in actions for a in ("RIDER_REQUEST_REUPLOAD", "RIDER_REUPLOAD"))

    # 9. Suspend
    sus = await client.post(
        f"/api/v1/admin/riders/{rider_id}/suspend",
        headers=ah,
        json={"note": "Policy review"},
    )
    assert sus.status_code == 200
    assert sus.json()["status"] == "SUSPENDED"


@pytest.mark.asyncio
async def test_reject_application(env):
    client: AsyncClient = env["client"]
    rh = {"Authorization": f"Bearer {env['rider_token']}"}
    ah = {"Authorization": f"Bearer {env['admin_token']}"}

    r = await client.post(
        "/api/v1/riders/me/register",
        headers=rh,
        json={"full_name": "Temp Rider", "nin": "CM11111111111", "date_of_birth": "1990-01-01"},
    )
    assert r.status_code == 200
    rider_id = r.json()["id"]

    # Minimal docs to submit
    await client.patch(
        "/api/v1/riders/me/vehicle-docs",
        headers=rh,
        json={
            "licence_number": "DL-1",
            "licence_expiry": date.today().replace(year=date.today().year + 1).isoformat(),
            "licence_class": "A",
            "motorcycle_reg": "UBX1",
            "insurance_policy": "P1",
            "insurance_reg": "UBX1",
            "insurance_valid_to": date.today().replace(year=date.today().year + 1).isoformat(),
        },
    )
    for dtype in (
        "NATIONAL_ID_FRONT",
        "NATIONAL_ID_BACK",
        "LICENCE_FRONT",
        "MOTORCYCLE",
        "INSURANCE",
        "SELFIE",
    ):
        await client.post(
            "/api/v1/riders/me/documents",
            headers=rh,
            json={"doc_type": dtype, "url": f"/m/{dtype}.jpg", "mime_type": "image/jpeg"},
        )
    await client.post("/api/v1/riders/me/submit-verification", headers=rh)

    rej = await client.post(
        f"/api/v1/admin/riders/{rider_id}/reject",
        headers=ah,
        json={"note": "Fake documents"},
    )
    assert rej.status_code == 200
    assert rej.json()["status"] == "REJECTED"
    ver = await client.get("/api/v1/riders/me/verification", headers=rh)
    assert ver.json()["status"] == "REJECTED"
    assert "Fake" in (ver.json().get("rejection_reason") or "")
