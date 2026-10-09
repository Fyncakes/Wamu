"""Rider KYC verification — registration, documents, AI signals, admin review.

AI results are verification *signals* for admins, not proof of government
document authenticity. A future authorized government verification API can
plug in after Wamu admin approval (left as an integration point).
"""

from __future__ import annotations

import re
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.audit import AuditLog
from app.models.rider import (
    RiderAiResult,
    RiderDocType,
    RiderDocument,
    RiderProfile,
    RiderStatus,
)
from app.models.user import User
from app.services.riders import assign_open_deliveries_to_rider, get_my_rider_profile

REQUIRED_DOC_TYPES = (
    RiderDocType.NATIONAL_ID_FRONT.value,
    RiderDocType.NATIONAL_ID_BACK.value,
    RiderDocType.LICENCE_FRONT.value,
    RiderDocType.MOTORCYCLE.value,
    RiderDocType.INSURANCE.value,
    RiderDocType.SELFIE.value,
)

# Statuses that may still edit / re-upload documents
EDITABLE_STATUSES = {
    RiderStatus.DRAFT.value,
    RiderStatus.SUBMITTED.value,
    RiderStatus.UNDER_REVIEW.value,
    RiderStatus.NEEDS_REUPLOAD.value,
    RiderStatus.REJECTED.value,
}

# Statuses visible in admin verification queue
QUEUE_STATUSES = {
    RiderStatus.SUBMITTED.value,
    RiderStatus.UNDER_REVIEW.value,
    RiderStatus.NEEDS_REUPLOAD.value,
}


def _parse_date(value: str | date | None) -> date | None:
    """Accept ISO dates, year-only, year-month, or common UG day/month/year forms."""
    if value is None or value == "":
        return None
    if isinstance(value, date):
        return value
    raw = str(value).strip()
    # Year only (e.g. "1994") → Jan 1 of that year
    if len(raw) == 4 and raw.isdigit():
        return date(int(raw), 1, 1)
    # Year-month (e.g. "1994-06")
    if len(raw) == 7 and raw[4] == "-" and raw[:4].isdigit() and raw[5:].isdigit():
        return date(int(raw[:4]), int(raw[5:]), 1)
    # DD/MM/YYYY or DD-MM-YYYY
    for sep in ("/", "-"):
        parts = raw.split(sep)
        if len(parts) == 3 and all(p.isdigit() for p in parts):
            a, b, c = (int(parts[0]), int(parts[1]), int(parts[2]))
            # Prefer day-first when first part > 12 (Uganda style)
            if a > 31 and len(parts[0]) == 4:
                # YYYY-MM-DD already handled below; YYYY/MM/DD
                try:
                    return date(a, b, c)
                except ValueError:
                    break
            if c >= 1900:  # day, month, year
                day, month, year = a, b, c
                if month > 12 and day <= 12:
                    day, month = month, day
                try:
                    return date(year, month, day)
                except ValueError as exc:
                    raise HTTPException(
                        status_code=400,
                        detail=f"Invalid date '{raw}' — use YYYY-MM-DD",
                    ) from exc
    try:
        return date.fromisoformat(raw[:10])
    except ValueError as exc:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid date '{raw}' — use YYYY-MM-DD (or DD/MM/YYYY)",
        ) from exc


async def next_wamu_rider_ref(db: AsyncSession) -> str:
    """Generate sequential refs like WAMU-R-000184."""
    count = await db.scalar(select(func.count()).select_from(RiderProfile)) or 0
    for _ in range(20):
        n = int(count) + 1
        ref = f"WAMU-R-{n:06d}"
        clash = await db.scalar(select(RiderProfile).where(RiderProfile.wamu_rider_ref == ref))
        if not clash:
            return ref
        count = n
    return f"WAMU-R-{uuid.uuid4().hex[:6].upper()}"


def public_rider_dict(rider: RiderProfile) -> dict:
    """Safe fields for customers / public list — no NIN, docs, or selfie."""
    return {
        "id": str(rider.id),
        "display_name": rider.display_name,
        "photo_url": rider.photo_url,
        "wamu_rider_ref": rider.wamu_rider_ref,
        "vehicle_type": rider.vehicle_type,
        "plate_number": rider.plate_number,
        "status": rider.status,
        "rating": float(rider.rating or 0),
        "delivery_count": rider.delivery_count,
        "ride_count": rider.ride_count,
        "available_delivery": rider.available_delivery,
        "available_rides": rider.available_rides,
        "lat": float(rider.lat) if rider.lat is not None else None,
        "lng": float(rider.lng) if rider.lng is not None else None,
    }


def _doc_map(rider: RiderProfile) -> dict[str, RiderDocument]:
    out: dict[str, RiderDocument] = {}
    for d in rider.documents or []:
        if d.is_current:
            out[d.doc_type] = d
    return out


def verification_payload(rider: RiderProfile, *, include_sensitive: bool) -> dict:
    """Rider-facing or admin-facing verification snapshot."""
    docs = _doc_map(rider)
    doc_list = []
    for dtype, d in docs.items():
        item = {
            "doc_type": dtype,
            "url": d.url if include_sensitive else None,
            "mime_type": d.mime_type,
            "uploaded": True,
            "updated_at": d.updated_at.isoformat() if d.updated_at else None,
        }
        if include_sensitive:
            item["object_key"] = d.object_key
            item["meta"] = d.meta_json
        doc_list.append(item)

    missing = [t for t in REQUIRED_DOC_TYPES if t not in docs]
    # licence back optional but recommended
    base = {
        "id": str(rider.id),
        "wamu_rider_ref": rider.wamu_rider_ref,
        "display_name": rider.display_name,
        "status": rider.status,
        "vehicle_type": rider.vehicle_type,
        "plate_number": rider.plate_number,
        "location_text": rider.location_text,
        "date_of_birth": rider.date_of_birth.isoformat() if rider.date_of_birth else None,
        "emergency_contact_name": rider.emergency_contact_name,
        "emergency_contact_phone": rider.emergency_contact_phone,
        "licence_number": rider.licence_number if include_sensitive else _mask(rider.licence_number),
        "licence_expiry": rider.licence_expiry.isoformat() if rider.licence_expiry else None,
        "licence_class": rider.licence_class,
        "motorcycle_reg": rider.motorcycle_reg,
        "motorcycle_ownership": rider.motorcycle_ownership,
        "insurance_policy": rider.insurance_policy if include_sensitive else _mask(rider.insurance_policy),
        "insurance_reg": rider.insurance_reg,
        "insurance_valid_from": rider.insurance_valid_from.isoformat()
        if rider.insurance_valid_from
        else None,
        "insurance_valid_to": rider.insurance_valid_to.isoformat()
        if rider.insurance_valid_to
        else None,
        "ai_result": rider.ai_result,
        "ai_checks": rider.ai_checks,
        "ai_ran_at": rider.ai_ran_at.isoformat() if rider.ai_ran_at else None,
        "admin_note": rider.admin_note,
        "rejection_reason": rider.rejection_reason,
        "reupload_fields": rider.reupload_fields,
        "submitted_at": rider.submitted_at.isoformat() if rider.submitted_at else None,
        "reviewed_at": rider.reviewed_at.isoformat() if rider.reviewed_at else None,
        "documents": doc_list,
        "missing_documents": missing,
        "can_submit": rider.status in EDITABLE_STATUSES and not missing,
        "can_go_online": rider.status == RiderStatus.APPROVED.value,
        # Advisory: government API is a future integration after licensed access.
        "government_verification": {
            "status": "NOT_CONNECTED",
            "note": (
                "Wamu AI checks are signals for admin review only. "
                "Authorized government document verification can be added later."
            ),
        },
    }
    if include_sensitive:
        base["nin"] = rider.nin
        base["phone"] = None  # filled by caller
        base["user_id"] = str(rider.user_id)
        base["reviewed_by_id"] = str(rider.reviewed_by_id) if rider.reviewed_by_id else None
    else:
        base["nin"] = _mask(rider.nin)
    return base


def _mask(value: str | None) -> str | None:
    if not value:
        return None
    if len(value) <= 4:
        return "****"
    return f"{'*' * (len(value) - 4)}{value[-4:]}"


async def register_rider(
    db: AsyncSession,
    user: User,
    *,
    full_name: str,
    date_of_birth: str | date | None = None,
    nin: str | None = None,
    emergency_contact_name: str | None = None,
    emergency_contact_phone: str | None = None,
    location_text: str | None = None,
    vehicle_type: str = "BODA",
    plate_number: str | None = None,
    lat: float | None = None,
    lng: float | None = None,
) -> RiderProfile:
    """Create or update personal registration (step 1)."""
    name = (full_name or "").strip()
    if len(name) < 2:
        raise HTTPException(status_code=400, detail="Full name is required")

    rider = await get_my_rider_profile(db, user)
    if rider and rider.status not in EDITABLE_STATUSES | {RiderStatus.SUBMITTED.value, RiderStatus.UNDER_REVIEW.value}:
        if rider.status == RiderStatus.APPROVED.value:
            # Allow profile contact updates only
            pass
        elif rider.status == RiderStatus.SUSPENDED.value:
            raise HTTPException(status_code=403, detail="Account suspended — contact support")

    if not rider:
        ref = await next_wamu_rider_ref(db)
        rider = RiderProfile(
            user_id=user.id,
            display_name=name,
            wamu_rider_ref=ref,
            vehicle_type=(vehicle_type or "BODA").upper(),
            plate_number=(plate_number or "").strip() or None,
            status=RiderStatus.DRAFT.value,
            available_delivery=False,
            available_rides=False,
            lat=Decimal(str(lat)) if lat is not None else Decimal("0.3476000"),
            lng=Decimal(str(lng)) if lng is not None else Decimal("32.5825000"),
        )
        db.add(rider)
    else:
        if rider.status in EDITABLE_STATUSES:
            rider.display_name = name
            if vehicle_type:
                rider.vehicle_type = vehicle_type.upper()
            if plate_number is not None:
                rider.plate_number = plate_number.strip() or None
            if lat is not None:
                rider.lat = Decimal(str(lat))
            if lng is not None:
                rider.lng = Decimal(str(lng))

    if rider.status in EDITABLE_STATUSES or rider.status in {
        RiderStatus.SUBMITTED.value,
        RiderStatus.UNDER_REVIEW.value,
        RiderStatus.APPROVED.value,
    }:
        dob = _parse_date(date_of_birth)
        if dob is not None:
            rider.date_of_birth = dob
        if nin is not None:
            rider.nin = nin.strip() or None
        if emergency_contact_name is not None:
            rider.emergency_contact_name = emergency_contact_name.strip() or None
        if emergency_contact_phone is not None:
            rider.emergency_contact_phone = emergency_contact_phone.strip() or None
        if location_text is not None:
            rider.location_text = location_text.strip() or None

    if user.profile is not None:
        user.profile.wants_to_ride = True
    await db.flush()
    return rider


async def update_licence_moto_insurance(
    db: AsyncSession,
    user: User,
    *,
    licence_number: str | None = None,
    licence_expiry: str | date | None = None,
    licence_class: str | None = None,
    motorcycle_reg: str | None = None,
    motorcycle_ownership: str | None = None,
    plate_number: str | None = None,
    insurance_policy: str | None = None,
    insurance_reg: str | None = None,
    insurance_valid_from: str | date | None = None,
    insurance_valid_to: str | date | None = None,
) -> RiderProfile:
    rider = await get_my_rider_profile(db, user)
    if not rider:
        raise HTTPException(status_code=404, detail="Register as a rider first")
    if rider.status not in EDITABLE_STATUSES:
        raise HTTPException(status_code=400, detail=f"Cannot edit docs while status is {rider.status}")

    if licence_number is not None:
        rider.licence_number = licence_number.strip() or None
    if licence_expiry is not None:
        rider.licence_expiry = _parse_date(licence_expiry)
    if licence_class is not None:
        rider.licence_class = licence_class.strip() or None
    if motorcycle_reg is not None:
        rider.motorcycle_reg = motorcycle_reg.strip() or None
        if not rider.plate_number:
            rider.plate_number = rider.motorcycle_reg
    if motorcycle_ownership is not None:
        rider.motorcycle_ownership = motorcycle_ownership.strip() or None
    if plate_number is not None:
        rider.plate_number = plate_number.strip() or None
    if insurance_policy is not None:
        rider.insurance_policy = insurance_policy.strip() or None
    if insurance_reg is not None:
        rider.insurance_reg = insurance_reg.strip() or None
    if insurance_valid_from is not None:
        rider.insurance_valid_from = _parse_date(insurance_valid_from)
    if insurance_valid_to is not None:
        rider.insurance_valid_to = _parse_date(insurance_valid_to)
    await db.flush()
    return rider


async def upsert_document(
    db: AsyncSession,
    user: User,
    *,
    doc_type: str,
    url: str,
    object_key: str | None = None,
    mime_type: str | None = None,
    meta: dict | None = None,
) -> RiderProfile:
    rider = await get_my_rider_profile(db, user)
    if not rider:
        raise HTTPException(status_code=404, detail="Register as a rider first")
    if rider.status not in EDITABLE_STATUSES:
        raise HTTPException(status_code=400, detail=f"Cannot upload while status is {rider.status}")

    dtype = doc_type.strip().upper()
    valid = {e.value for e in RiderDocType}
    if dtype not in valid:
        raise HTTPException(status_code=400, detail=f"doc_type must be one of {sorted(valid)}")
    if not url or not str(url).strip():
        raise HTTPException(status_code=400, detail="url is required")

    # Mark previous current docs of this type as superseded
    for d in list(rider.documents or []):
        if d.doc_type == dtype and d.is_current:
            d.is_current = False

    db.add(
        RiderDocument(
            rider_id=rider.id,
            doc_type=dtype,
            url=str(url).strip(),
            object_key=object_key,
            mime_type=mime_type,
            meta_json=meta,
            is_current=True,
        )
    )
    # Selfie also becomes profile photo for ops (not exposed as KYC to customers beyond photo_url)
    if dtype == RiderDocType.SELFIE.value:
        rider.photo_url = str(url).strip()

    # After reupload of requested fields, clear those from the list when uploaded
    if rider.status == RiderStatus.NEEDS_REUPLOAD.value and rider.reupload_fields:
        remaining = [f for f in rider.reupload_fields if f != dtype]
        rider.reupload_fields = remaining or None

    await db.flush()
    await db.refresh(rider, attribute_names=["documents"])
    return rider


def run_ai_verification(rider: RiderProfile) -> tuple[str, dict]:
    """Heuristic AI *signals* — not government document authenticity.

    Future: swap this for OCR + face-match + authorized NIRA/URAetc. APIs.
    """
    docs = _doc_map(rider)
    checks: dict[str, str] = {}

    def _ok(key: str, passed: bool, review: bool = False) -> None:
        if passed and not review:
            checks[key] = RiderAiResult.PASS.value
        elif review:
            checks[key] = RiderAiResult.REVIEW.value
        else:
            checks[key] = RiderAiResult.FAIL.value

    _ok("national_id", RiderDocType.NATIONAL_ID_FRONT.value in docs and RiderDocType.NATIONAL_ID_BACK.value in docs)
    _ok("driving_licence", RiderDocType.LICENCE_FRONT.value in docs and bool(rider.licence_number))
    _ok("motorcycle_documents", RiderDocType.MOTORCYCLE.value in docs and bool(rider.motorcycle_reg or rider.plate_number))
    _ok("insurance", RiderDocType.INSURANCE.value in docs and bool(rider.insurance_policy))
    _ok("selfie", RiderDocType.SELFIE.value in docs)

    # Consistency: plate vs insurance reg, age-ish DOB present, NIN shape
    consistency_review = False
    consistency_fail = False
    if rider.insurance_reg and rider.motorcycle_reg:
        if rider.insurance_reg.strip().upper() != rider.motorcycle_reg.strip().upper():
            consistency_review = True
    if rider.plate_number and rider.motorcycle_reg:
        if rider.plate_number.strip().upper() != rider.motorcycle_reg.strip().upper():
            consistency_review = True
    if not rider.date_of_birth:
        consistency_review = True
    if rider.nin:
        nin_clean = re.sub(r"\s+", "", rider.nin)
        if len(nin_clean) < 8:
            consistency_fail = True
    else:
        consistency_review = True

    if consistency_fail:
        checks["information_consistency"] = RiderAiResult.FAIL.value
    elif consistency_review:
        checks["information_consistency"] = RiderAiResult.REVIEW.value
    else:
        checks["information_consistency"] = RiderAiResult.PASS.value

    # Licence expiry
    if rider.licence_expiry and rider.licence_expiry < date.today():
        checks["driving_licence"] = RiderAiResult.FAIL.value
    if rider.insurance_valid_to and rider.insurance_valid_to < date.today():
        checks["insurance"] = RiderAiResult.FAIL.value

    # Duplicate-ish: same NIN already approved (signal only)
    checks["duplicate_account"] = RiderAiResult.PASS.value  # filled async by caller if needed

    values = list(checks.values())
    if RiderAiResult.FAIL.value in values:
        overall = RiderAiResult.FAIL.value
    elif RiderAiResult.REVIEW.value in values:
        overall = RiderAiResult.REVIEW.value
    else:
        overall = RiderAiResult.PASS.value

    return overall, {
        "checks": checks,
        "overall": overall,
        "disclaimer": (
            "AI results are Wamu verification signals for admin review. "
            "They do not prove a government document is genuine unless "
            "an authorized government verification source is connected."
        ),
    }


async def _check_duplicate_nin(db: AsyncSession, rider: RiderProfile, checks: dict) -> None:
    if not rider.nin:
        return
    other = await db.scalar(
        select(RiderProfile).where(
            RiderProfile.nin == rider.nin,
            RiderProfile.id != rider.id,
            RiderProfile.deleted_at.is_(None),
            RiderProfile.status == RiderStatus.APPROVED.value,
        )
    )
    if other:
        checks["duplicate_account"] = RiderAiResult.REVIEW.value


async def submit_for_verification(db: AsyncSession, user: User) -> RiderProfile:
    rider = await db.scalar(
        select(RiderProfile)
        .where(RiderProfile.user_id == user.id, RiderProfile.deleted_at.is_(None))
        .options(selectinload(RiderProfile.documents))
    )
    if not rider:
        raise HTTPException(status_code=404, detail="Register as a rider first")
    if rider.status not in EDITABLE_STATUSES:
        raise HTTPException(status_code=400, detail=f"Cannot submit while status is {rider.status}")

    docs = _doc_map(rider)
    missing = [t for t in REQUIRED_DOC_TYPES if t not in docs]
    if missing:
        raise HTTPException(
            status_code=400,
            detail={"message": "Missing required documents", "missing": missing},
        )
    if not rider.display_name or not rider.nin:
        raise HTTPException(status_code=400, detail="Full name and NIN are required before submit")

    overall, payload = run_ai_verification(rider)
    await _check_duplicate_nin(db, rider, payload["checks"])
    # Recompute overall after duplicate check
    vals = list(payload["checks"].values())
    if RiderAiResult.FAIL.value in vals:
        overall = RiderAiResult.FAIL.value
    elif RiderAiResult.REVIEW.value in vals:
        overall = RiderAiResult.REVIEW.value
    else:
        overall = RiderAiResult.PASS.value
    payload["overall"] = overall

    rider.ai_result = overall
    rider.ai_checks = payload
    rider.ai_ran_at = datetime.now(timezone.utc)
    rider.submitted_at = datetime.now(timezone.utc)
    rider.rejection_reason = None
    # Always land in admin queue — AI never auto-approves (signals only).
    if overall == RiderAiResult.FAIL.value:
        rider.status = RiderStatus.UNDER_REVIEW.value  # still admin-visible; may reject
    else:
        rider.status = RiderStatus.UNDER_REVIEW.value
    rider.available_delivery = False
    rider.available_rides = False

    db.add(
        AuditLog(
            actor_id=user.id,
            action="RIDER_SUBMIT_VERIFICATION",
            entity_type="rider_profile",
            entity_id=rider.id,
            metadata_json={"ai_result": overall, "wamu_rider_ref": rider.wamu_rider_ref},
        )
    )
    await db.flush()
    return rider


async def get_my_verification(db: AsyncSession, user: User) -> dict:
    rider = await db.scalar(
        select(RiderProfile)
        .where(RiderProfile.user_id == user.id, RiderProfile.deleted_at.is_(None))
        .options(selectinload(RiderProfile.documents))
    )
    if not rider:
        raise HTTPException(status_code=404, detail="Not enrolled as a rider")
    payload = verification_payload(rider, include_sensitive=False)
    # Rider may see their own masked sensitive fields + own document URLs
    docs = []
    for d in _doc_map(rider).values():
        docs.append(
            {
                "doc_type": d.doc_type,
                "url": d.url,
                "mime_type": d.mime_type,
                "uploaded": True,
                "updated_at": d.updated_at.isoformat() if d.updated_at else None,
            }
        )
    payload["documents"] = docs
    payload["nin"] = _mask(rider.nin)
    return payload


async def admin_verification_queue(db: AsyncSession, status: str | None = None) -> list[dict]:
    q = (
        select(RiderProfile)
        .where(RiderProfile.deleted_at.is_(None))
        .options(selectinload(RiderProfile.documents))
        .order_by(RiderProfile.created_at.desc())
        .limit(200)
    )
    if status:
        st = status.upper()
        if st == "PENDING":
            q = q.where(RiderProfile.status.in_(list(QUEUE_STATUSES | {RiderStatus.DRAFT.value})))
        elif st == "QUEUE":
            q = q.where(RiderProfile.status.in_(list(QUEUE_STATUSES)))
        else:
            q = q.where(RiderProfile.status == st)
    else:
        q = q.where(
            RiderProfile.status.in_(
                list(QUEUE_STATUSES | {RiderStatus.DRAFT.value, RiderStatus.REJECTED.value})
            )
        )

    rows = (await db.scalars(q)).all()
    out = []
    for r in rows:
        u = await db.get(User, r.user_id)
        docs = _doc_map(r)
        out.append(
            {
                "id": str(r.id),
                "wamu_rider_ref": r.wamu_rider_ref,
                "display_name": r.display_name,
                "phone": u.phone if u else None,
                "status": r.status,
                "ai_result": r.ai_result,
                "ai_checks": (r.ai_checks or {}).get("checks") if isinstance(r.ai_checks, dict) else None,
                "document_count": len(docs),
                "missing_documents": [t for t in REQUIRED_DOC_TYPES if t not in docs],
                "submitted_at": r.submitted_at.isoformat() if r.submitted_at else None,
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
        )
    return out


async def admin_verification_detail(db: AsyncSession, rider_id: uuid.UUID) -> dict:
    rider = await db.scalar(
        select(RiderProfile)
        .where(RiderProfile.id == rider_id, RiderProfile.deleted_at.is_(None))
        .options(selectinload(RiderProfile.documents))
    )
    if not rider:
        raise HTTPException(status_code=404, detail="Rider not found")
    u = await db.get(User, rider.user_id)
    payload = verification_payload(rider, include_sensitive=True)
    payload["phone"] = u.phone if u else None
    return payload


async def admin_moderation_action(
    db: AsyncSession,
    admin: User,
    rider_id: uuid.UUID,
    *,
    action: str,
    note: str | None = None,
    reupload_fields: list[str] | None = None,
) -> dict:
    from datetime import datetime, timezone

    rider = await db.scalar(
        select(RiderProfile)
        .where(RiderProfile.id == rider_id, RiderProfile.deleted_at.is_(None))
        .options(selectinload(RiderProfile.documents))
    )
    if not rider:
        raise HTTPException(status_code=404, detail="Rider not found")

    act = action.upper()
    now = datetime.now(timezone.utc)

    if act == "APPROVE":
        rider.status = RiderStatus.APPROVED.value
        rider.available_delivery = True
        rider.available_rides = True
        rider.admin_note = note
        rider.rejection_reason = None
        rider.reupload_fields = None
        rider.reviewed_at = now
        rider.reviewed_by_id = admin.id
        await db.flush()
        await assign_open_deliveries_to_rider(db, rider)
    elif act == "REJECT":
        rider.status = RiderStatus.REJECTED.value
        rider.available_delivery = False
        rider.available_rides = False
        rider.rejection_reason = note or "Application rejected"
        rider.admin_note = note
        rider.reviewed_at = now
        rider.reviewed_by_id = admin.id
    elif act in {"REQUEST_REUPLOAD", "REUPLOAD"}:
        fields = reupload_fields or []
        rider.status = RiderStatus.NEEDS_REUPLOAD.value
        rider.available_delivery = False
        rider.available_rides = False
        rider.reupload_fields = fields or list(REQUIRED_DOC_TYPES)
        rider.admin_note = note
        rider.reviewed_at = now
        rider.reviewed_by_id = admin.id
    elif act == "SUSPEND":
        rider.status = RiderStatus.SUSPENDED.value
        rider.available_delivery = False
        rider.available_rides = False
        rider.admin_note = note
        rider.reviewed_at = now
        rider.reviewed_by_id = admin.id
    else:
        raise HTTPException(
            status_code=400,
            detail="action must be APPROVE, REJECT, REQUEST_REUPLOAD, or SUSPEND",
        )

    db.add(
        AuditLog(
            actor_id=admin.id,
            action=f"RIDER_{act}",
            entity_type="rider_profile",
            entity_id=rider.id,
            metadata_json={
                "note": note,
                "status": rider.status,
                "reupload_fields": rider.reupload_fields,
                "ai_result": rider.ai_result,
                "wamu_rider_ref": rider.wamu_rider_ref,
            },
        )
    )
    await db.flush()
    return {
        "id": str(rider.id),
        "status": rider.status,
        "wamu_rider_ref": rider.wamu_rider_ref,
        "display_name": rider.display_name,
        "available_delivery": rider.available_delivery,
        "reupload_fields": rider.reupload_fields,
        "ai_result": rider.ai_result,
    }
