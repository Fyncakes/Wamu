"""Merchant KYC — owner identity docs, AI signals, admin review.

Mirrors rider verification. Enforcement is gated by kyc_policy flags (off by default).
AI results are admin signals only — not government document proof.
"""

from __future__ import annotations

import re
import uuid
from datetime import date, datetime, timezone

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.audit import AuditLog
from app.models.business import (
    Business,
    MerchantAiResult,
    MerchantDocType,
    MerchantDocument,
    MerchantKycStatus,
    VerificationStatus,
)
from app.models.notification import Notification
from app.models.user import User

REQUIRED_DOC_TYPES = (
    MerchantDocType.OWNER_ID_FRONT.value,
    MerchantDocType.OWNER_ID_BACK.value,
    MerchantDocType.SELFIE.value,
    MerchantDocType.BUSINESS_PREMISES.value,
)

OPTIONAL_DOC_TYPES = (MerchantDocType.TIN_CERT.value,)

EDITABLE_STATUSES = {
    MerchantKycStatus.DRAFT.value,
    MerchantKycStatus.SUBMITTED.value,
    MerchantKycStatus.UNDER_REVIEW.value,
    MerchantKycStatus.NEEDS_REUPLOAD.value,
    MerchantKycStatus.REJECTED.value,
}

QUEUE_STATUSES = {
    MerchantKycStatus.SUBMITTED.value,
    MerchantKycStatus.UNDER_REVIEW.value,
    MerchantKycStatus.NEEDS_REUPLOAD.value,
}


def _parse_date(value: str | date | None) -> date | None:
    if value is None or value == "":
        return None
    if isinstance(value, date):
        return value
    raw = str(value).strip()
    try:
        return date.fromisoformat(raw[:10])
    except ValueError as exc:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid date '{raw}' — use YYYY-MM-DD",
        ) from exc


def _mask(value: str | None) -> str | None:
    if not value:
        return None
    if len(value) <= 4:
        return "****"
    return f"{'*' * (len(value) - 4)}{value[-4:]}"


def _doc_map(business: Business) -> dict[str, MerchantDocument]:
    out: dict[str, MerchantDocument] = {}
    for d in business.kyc_documents or []:
        if d.is_current:
            out[d.doc_type] = d
    return out


async def _require_owner(db: AsyncSession, user: User, business_id: uuid.UUID) -> Business:
    business = await db.scalar(
        select(Business)
        .where(Business.id == business_id, Business.deleted_at.is_(None))
        .options(selectinload(Business.kyc_documents))
    )
    if not business:
        raise HTTPException(status_code=404, detail="Business not found")
    if business.owner_id != user.id and user.role != "ADMIN":
        raise HTTPException(status_code=403, detail="Only the shop owner can manage KYC")
    return business


def verification_payload(business: Business, *, include_sensitive: bool) -> dict:
    docs = _doc_map(business)
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
    base = {
        "business_id": str(business.id),
        "business_name": business.name,
        "verification_status": business.verification_status,
        "kyc_status": business.kyc_status,
        "owner_full_name": business.owner_full_name,
        "owner_date_of_birth": (
            business.owner_date_of_birth.isoformat() if business.owner_date_of_birth else None
        ),
        "tin": business.tin if include_sensitive else _mask(business.tin),
        "ai_result": business.kyc_ai_result,
        "ai_checks": business.kyc_ai_checks,
        "ai_ran_at": business.kyc_ai_ran_at.isoformat() if business.kyc_ai_ran_at else None,
        "admin_note": business.kyc_admin_note,
        "rejection_reason": business.kyc_rejection_reason,
        "reupload_fields": business.kyc_reupload_fields,
        "submitted_at": (
            business.kyc_submitted_at.isoformat() if business.kyc_submitted_at else None
        ),
        "reviewed_at": (
            business.kyc_reviewed_at.isoformat() if business.kyc_reviewed_at else None
        ),
        "documents": doc_list,
        "missing_documents": missing,
        "optional_documents": list(OPTIONAL_DOC_TYPES),
        "can_submit": business.kyc_status in EDITABLE_STATUSES and not missing,
        "government_verification": {
            "status": "NOT_CONNECTED",
            "note": (
                "Wamu AI checks are signals for admin review only. "
                "Authorized government document verification can be added later."
            ),
        },
    }
    if include_sensitive:
        base["owner_nin"] = business.owner_nin
        base["owner_id"] = str(business.owner_id)
        base["reviewed_by_id"] = (
            str(business.kyc_reviewed_by_id) if business.kyc_reviewed_by_id else None
        )
    else:
        base["owner_nin"] = _mask(business.owner_nin)
    return base


async def register_owner_identity(
    db: AsyncSession,
    user: User,
    business_id: uuid.UUID,
    *,
    owner_full_name: str,
    owner_nin: str | None = None,
    owner_date_of_birth: str | date | None = None,
    tin: str | None = None,
) -> dict:
    business = await _require_owner(db, user, business_id)
    if business.kyc_status not in EDITABLE_STATUSES | {
        MerchantKycStatus.APPROVED.value,
    }:
        if business.kyc_status == MerchantKycStatus.APPROVED.value:
            pass
        else:
            raise HTTPException(
                status_code=400,
                detail=f"Cannot edit KYC while status is {business.kyc_status}",
            )

    name = (owner_full_name or "").strip()
    if len(name) < 2:
        raise HTTPException(status_code=400, detail="Owner full name is required")

    if business.kyc_status in EDITABLE_STATUSES or business.kyc_status == MerchantKycStatus.APPROVED.value:
        business.owner_full_name = name
        if owner_nin is not None:
            business.owner_nin = owner_nin.strip() or None
        dob = _parse_date(owner_date_of_birth)
        if dob is not None:
            business.owner_date_of_birth = dob
        if tin is not None:
            business.tin = tin.strip() or None
        if business.kyc_status == MerchantKycStatus.DRAFT.value:
            # keep DRAFT until submit
            pass

    await db.flush()
    return await get_my_verification(db, user, business_id)


async def upsert_document(
    db: AsyncSession,
    user: User,
    business_id: uuid.UUID,
    *,
    doc_type: str,
    url: str,
    object_key: str | None = None,
    mime_type: str | None = None,
    meta: dict | None = None,
) -> dict:
    business = await _require_owner(db, user, business_id)
    if business.kyc_status not in EDITABLE_STATUSES:
        raise HTTPException(
            status_code=400,
            detail=f"Cannot upload while KYC status is {business.kyc_status}",
        )

    dtype = doc_type.strip().upper()
    valid = {e.value for e in MerchantDocType}
    if dtype not in valid:
        raise HTTPException(status_code=400, detail=f"doc_type must be one of {sorted(valid)}")
    if not url or not str(url).strip():
        raise HTTPException(status_code=400, detail="url is required")

    for d in list(business.kyc_documents or []):
        if d.doc_type == dtype and d.is_current:
            d.is_current = False

    db.add(
        MerchantDocument(
            business_id=business.id,
            doc_type=dtype,
            url=str(url).strip(),
            object_key=object_key,
            mime_type=mime_type,
            meta_json=meta,
            is_current=True,
        )
    )

    if business.kyc_status == MerchantKycStatus.NEEDS_REUPLOAD.value and business.kyc_reupload_fields:
        remaining = [f for f in business.kyc_reupload_fields if f != dtype]
        business.kyc_reupload_fields = remaining or None

    await db.flush()
    await db.refresh(business, attribute_names=["kyc_documents"])
    return await get_my_verification(db, user, business_id)


def run_ai_verification(business: Business) -> tuple[str, dict]:
    docs = _doc_map(business)
    checks: dict[str, str] = {}

    def _ok(key: str, passed: bool, review: bool = False) -> None:
        if passed and not review:
            checks[key] = MerchantAiResult.PASS.value
        elif review:
            checks[key] = MerchantAiResult.REVIEW.value
        else:
            checks[key] = MerchantAiResult.FAIL.value

    _ok(
        "national_id",
        MerchantDocType.OWNER_ID_FRONT.value in docs
        and MerchantDocType.OWNER_ID_BACK.value in docs,
    )
    _ok("selfie", MerchantDocType.SELFIE.value in docs)
    _ok("business_premises", MerchantDocType.BUSINESS_PREMISES.value in docs)
    if MerchantDocType.TIN_CERT.value in docs or business.tin:
        _ok("tin", bool(business.tin) or MerchantDocType.TIN_CERT.value in docs, review=not bool(business.tin))
    else:
        checks["tin"] = MerchantAiResult.REVIEW.value  # optional — flag for admin glance

    consistency_review = False
    consistency_fail = False
    if not business.owner_date_of_birth:
        consistency_review = True
    if business.owner_nin:
        nin_clean = re.sub(r"\s+", "", business.owner_nin)
        if len(nin_clean) < 8:
            consistency_fail = True
    else:
        consistency_review = True
    if not business.owner_full_name:
        consistency_fail = True

    if consistency_fail:
        checks["information_consistency"] = MerchantAiResult.FAIL.value
    elif consistency_review:
        checks["information_consistency"] = MerchantAiResult.REVIEW.value
    else:
        checks["information_consistency"] = MerchantAiResult.PASS.value

    checks["duplicate_account"] = MerchantAiResult.PASS.value

    values = list(checks.values())
    if MerchantAiResult.FAIL.value in values:
        overall = MerchantAiResult.FAIL.value
    elif MerchantAiResult.REVIEW.value in values:
        overall = MerchantAiResult.REVIEW.value
    else:
        overall = MerchantAiResult.PASS.value

    return overall, {
        "checks": checks,
        "overall": overall,
        "disclaimer": (
            "AI results are Wamu verification signals for admin review. "
            "They do not prove a government document is genuine unless "
            "an authorized government verification source is connected."
        ),
    }


async def _check_duplicate_nin(db: AsyncSession, business: Business, checks: dict) -> None:
    if not business.owner_nin:
        return
    other = await db.scalar(
        select(Business).where(
            Business.owner_nin == business.owner_nin,
            Business.id != business.id,
            Business.deleted_at.is_(None),
            Business.kyc_status == MerchantKycStatus.APPROVED.value,
        )
    )
    if other:
        checks["duplicate_account"] = MerchantAiResult.REVIEW.value


async def submit_for_verification(
    db: AsyncSession, user: User, business_id: uuid.UUID
) -> dict:
    business = await _require_owner(db, user, business_id)
    if business.kyc_status not in EDITABLE_STATUSES:
        raise HTTPException(
            status_code=400,
            detail=f"Cannot submit while KYC status is {business.kyc_status}",
        )

    docs = _doc_map(business)
    missing = [t for t in REQUIRED_DOC_TYPES if t not in docs]
    if missing:
        raise HTTPException(
            status_code=400,
            detail={"message": "Missing required documents", "missing": missing},
        )
    if not business.owner_full_name or not business.owner_nin:
        raise HTTPException(
            status_code=400, detail="Owner full name and NIN are required before submit"
        )

    overall, payload = run_ai_verification(business)
    await _check_duplicate_nin(db, business, payload["checks"])
    vals = list(payload["checks"].values())
    if MerchantAiResult.FAIL.value in vals:
        overall = MerchantAiResult.FAIL.value
    elif MerchantAiResult.REVIEW.value in vals:
        overall = MerchantAiResult.REVIEW.value
    else:
        overall = MerchantAiResult.PASS.value
    payload["overall"] = overall

    now = datetime.now(timezone.utc)
    business.kyc_ai_result = overall
    business.kyc_ai_checks = payload
    business.kyc_ai_ran_at = now
    business.kyc_submitted_at = now
    business.kyc_rejection_reason = None
    business.kyc_status = MerchantKycStatus.UNDER_REVIEW.value
    # Customer-facing badge: awaiting admin
    if business.verification_status != VerificationStatus.VERIFIED.value:
        business.verification_status = VerificationStatus.PENDING.value

    db.add(
        AuditLog(
            actor_id=user.id,
            action="MERCHANT_SUBMIT_VERIFICATION",
            entity_type="business",
            entity_id=business.id,
            metadata_json={"ai_result": overall, "business_name": business.name},
        )
    )
    await db.flush()
    return await get_my_verification(db, user, business_id)


async def get_my_verification(
    db: AsyncSession, user: User, business_id: uuid.UUID
) -> dict:
    business = await _require_owner(db, user, business_id)
    payload = verification_payload(business, include_sensitive=False)
    docs = []
    for d in _doc_map(business).values():
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
    payload["owner_nin"] = _mask(business.owner_nin)
    return payload


async def admin_verification_queue(db: AsyncSession, status: str | None = None) -> list[dict]:
    q = (
        select(Business)
        .where(Business.deleted_at.is_(None))
        .options(selectinload(Business.kyc_documents))
        .order_by(Business.created_at.desc())
        .limit(200)
    )
    if status:
        st = status.upper()
        if st == "PENDING":
            q = q.where(
                Business.kyc_status.in_(
                    list(QUEUE_STATUSES | {MerchantKycStatus.DRAFT.value})
                )
            )
        elif st == "QUEUE":
            q = q.where(Business.kyc_status.in_(list(QUEUE_STATUSES)))
        else:
            q = q.where(Business.kyc_status == st)
    else:
        q = q.where(
            Business.kyc_status.in_(
                list(
                    QUEUE_STATUSES
                    | {MerchantKycStatus.DRAFT.value, MerchantKycStatus.REJECTED.value}
                )
            )
        )

    rows = (await db.scalars(q)).all()
    out = []
    for b in rows:
        u = await db.get(User, b.owner_id)
        docs = _doc_map(b)
        out.append(
            {
                "id": str(b.id),
                "business_name": b.name,
                "owner_full_name": b.owner_full_name,
                "phone": u.phone if u else b.phone,
                "kyc_status": b.kyc_status,
                "verification_status": b.verification_status,
                "ai_result": b.kyc_ai_result,
                "ai_checks": (
                    (b.kyc_ai_checks or {}).get("checks")
                    if isinstance(b.kyc_ai_checks, dict)
                    else None
                ),
                "document_count": len(docs),
                "missing_documents": [t for t in REQUIRED_DOC_TYPES if t not in docs],
                "submitted_at": b.kyc_submitted_at.isoformat() if b.kyc_submitted_at else None,
                "created_at": b.created_at.isoformat() if b.created_at else None,
            }
        )
    return out


async def admin_verification_detail(db: AsyncSession, business_id: uuid.UUID) -> dict:
    business = await db.scalar(
        select(Business)
        .where(Business.id == business_id, Business.deleted_at.is_(None))
        .options(selectinload(Business.kyc_documents))
    )
    if not business:
        raise HTTPException(status_code=404, detail="Business not found")
    u = await db.get(User, business.owner_id)
    payload = verification_payload(business, include_sensitive=True)
    payload["phone"] = u.phone if u else business.phone
    return payload


async def admin_moderation_action(
    db: AsyncSession,
    admin: User,
    business_id: uuid.UUID,
    *,
    action: str,
    note: str | None = None,
    reupload_fields: list[str] | None = None,
) -> dict:
    business = await db.scalar(
        select(Business)
        .where(Business.id == business_id, Business.deleted_at.is_(None))
        .options(selectinload(Business.kyc_documents))
    )
    if not business:
        raise HTTPException(status_code=404, detail="Business not found")

    act = action.upper()
    now = datetime.now(timezone.utc)

    if act == "APPROVE":
        business.kyc_status = MerchantKycStatus.APPROVED.value
        business.verification_status = VerificationStatus.VERIFIED.value
        business.kyc_admin_note = note
        business.kyc_rejection_reason = None
        business.kyc_reupload_fields = None
        business.kyc_reviewed_at = now
        business.kyc_reviewed_by_id = admin.id
        db.add(
            Notification(
                user_id=business.owner_id,
                type="BUSINESS_VERIFIED",
                title="Business verified",
                body=f"{business.name} is verified on Wamu — customers will see the badge.",
                data={"business_id": str(business.id), "audience": "merchant"},
            )
        )
    elif act == "REJECT":
        business.kyc_status = MerchantKycStatus.REJECTED.value
        business.kyc_rejection_reason = note or "Application rejected"
        business.kyc_admin_note = note
        business.kyc_reviewed_at = now
        business.kyc_reviewed_by_id = admin.id
        if business.verification_status == VerificationStatus.PENDING.value:
            business.verification_status = VerificationStatus.UNVERIFIED.value
    elif act in {"REQUEST_REUPLOAD", "REUPLOAD"}:
        fields = reupload_fields or []
        business.kyc_status = MerchantKycStatus.NEEDS_REUPLOAD.value
        business.kyc_reupload_fields = fields or list(REQUIRED_DOC_TYPES)
        business.kyc_admin_note = note
        business.kyc_reviewed_at = now
        business.kyc_reviewed_by_id = admin.id
    elif act == "SUSPEND":
        business.kyc_status = MerchantKycStatus.REJECTED.value
        business.verification_status = VerificationStatus.SUSPENDED.value
        business.kyc_admin_note = note
        business.kyc_reviewed_at = now
        business.kyc_reviewed_by_id = admin.id
    else:
        raise HTTPException(
            status_code=400,
            detail="action must be APPROVE, REJECT, REQUEST_REUPLOAD, or SUSPEND",
        )

    db.add(
        AuditLog(
            actor_id=admin.id,
            action=f"MERCHANT_KYC_{act}",
            entity_type="business",
            entity_id=business.id,
            metadata_json={
                "note": note,
                "kyc_status": business.kyc_status,
                "verification_status": business.verification_status,
                "reupload_fields": business.kyc_reupload_fields,
                "ai_result": business.kyc_ai_result,
            },
        )
    )
    await db.flush()
    return {
        "id": str(business.id),
        "kyc_status": business.kyc_status,
        "verification_status": business.verification_status,
        "business_name": business.name,
        "reupload_fields": business.kyc_reupload_fields,
        "ai_result": business.kyc_ai_result,
    }


async def assert_payout_allowed(db: AsyncSession, business: Business) -> None:
    """Raise 403 when policy requires verified KYC and shop is not verified."""
    from app.services import kyc_policy

    if not await kyc_policy.require_merchant_verified_for_payout(db):
        return
    if business.verification_status != VerificationStatus.VERIFIED.value:
        raise HTTPException(
            status_code=403,
            detail=(
                "Shop verification required before payouts. "
                "Complete merchant KYC or ask an admin to verify the business."
            ),
        )
