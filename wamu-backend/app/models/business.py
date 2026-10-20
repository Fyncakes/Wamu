"""Categories, businesses, members, locations, and merchant KYC documents."""

from __future__ import annotations

import enum
import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import TYPE_CHECKING

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    JSON,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import SoftDeleteMixin, TimestampMixin, UUIDMixin, VersionMixin

if TYPE_CHECKING:
    from app.models.product import Product


class BusinessStatus(str, enum.Enum):
    ACTIVE = "ACTIVE"
    INACTIVE = "INACTIVE"
    SUSPENDED = "SUSPENDED"


class VerificationStatus(str, enum.Enum):
    UNVERIFIED = "UNVERIFIED"
    PENDING = "PENDING"
    VERIFIED = "VERIFIED"
    SUSPENDED = "SUSPENDED"


class MerchantKycStatus(str, enum.Enum):
    """Document workflow for shop owners — independent of customer-facing badge."""

    DRAFT = "DRAFT"
    SUBMITTED = "SUBMITTED"
    UNDER_REVIEW = "UNDER_REVIEW"
    NEEDS_REUPLOAD = "NEEDS_REUPLOAD"
    APPROVED = "APPROVED"
    REJECTED = "REJECTED"


class MerchantDocType(str, enum.Enum):
    OWNER_ID_FRONT = "OWNER_ID_FRONT"
    OWNER_ID_BACK = "OWNER_ID_BACK"
    SELFIE = "SELFIE"
    BUSINESS_PREMISES = "BUSINESS_PREMISES"
    TIN_CERT = "TIN_CERT"  # optional


class MerchantAiResult(str, enum.Enum):
    PASS = "PASS"
    REVIEW = "REVIEW"
    FAIL = "FAIL"


class MemberRole(str, enum.Enum):
    OWNER = "OWNER"
    MANAGER = "MANAGER"
    STAFF = "STAFF"


class Category(UUIDMixin, Base):
    __tablename__ = "categories"

    name: Mapped[str] = mapped_column(String(100), unique=True, nullable=False)
    slug: Mapped[str] = mapped_column(String(120), unique=True, nullable=False, index=True)
    description: Mapped[str | None] = mapped_column(Text)
    icon_url: Mapped[str | None] = mapped_column(Text)
    parent_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("categories.id"), nullable=True, index=True
    )
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class Business(UUIDMixin, TimestampMixin, SoftDeleteMixin, VersionMixin, Base):
    __tablename__ = "businesses"
    __table_args__ = (
        CheckConstraint("rating >= 0 AND rating <= 5", name="ck_business_rating"),
    )

    owner_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True
    )
    name: Mapped[str] = mapped_column(String(200), nullable=False)
    slug: Mapped[str] = mapped_column(String(220), unique=True, nullable=False, index=True)
    description: Mapped[str | None] = mapped_column(Text)
    phone: Mapped[str | None] = mapped_column(String(20))
    # MoMo destination for non-custodial disbursements (falls back to phone / owner)
    payout_phone: Mapped[str | None] = mapped_column(String(20))
    payout_provider: Mapped[str | None] = mapped_column(String(20))
    email: Mapped[str | None] = mapped_column(String(255))
    category_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("categories.id"), nullable=True, index=True
    )
    status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=BusinessStatus.ACTIVE.value
    )
    verification_status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=VerificationStatus.UNVERIFIED.value
    )
    logo_url: Mapped[str | None] = mapped_column(Text)
    cover_url: Mapped[str | None] = mapped_column(Text)
    rating: Mapped[Decimal] = mapped_column(Numeric(3, 2), nullable=False, default=Decimal("0"))
    review_count: Mapped[int] = mapped_column(nullable=False, default=0)

    # —— Merchant KYC (admin-only; never on public catalog) ——
    kyc_status: Mapped[str] = mapped_column(
        String(20), nullable=False, default=MerchantKycStatus.DRAFT.value
    )
    owner_full_name: Mapped[str | None] = mapped_column(String(120))
    owner_nin: Mapped[str | None] = mapped_column(String(40))
    owner_date_of_birth: Mapped[date | None] = mapped_column(Date)
    tin: Mapped[str | None] = mapped_column(String(40))  # optional until ops requires it
    kyc_ai_result: Mapped[str | None] = mapped_column(String(20))
    kyc_ai_checks: Mapped[dict | None] = mapped_column(JSON)
    kyc_ai_ran_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    kyc_admin_note: Mapped[str | None] = mapped_column(Text)
    kyc_rejection_reason: Mapped[str | None] = mapped_column(Text)
    kyc_reupload_fields: Mapped[list | None] = mapped_column(JSON)
    kyc_submitted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    kyc_reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    kyc_reviewed_by_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=True
    )

    members: Mapped[list[BusinessMember]] = relationship(
        "BusinessMember", back_populates="business", cascade="all, delete-orphan"
    )
    location: Mapped[Location | None] = relationship(
        "Location", back_populates="business", uselist=False, cascade="all, delete-orphan"
    )
    products: Mapped[list[Product]] = relationship("Product", back_populates="business")
    kyc_documents: Mapped[list["MerchantDocument"]] = relationship(
        "MerchantDocument",
        back_populates="business",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class MerchantDocument(UUIDMixin, TimestampMixin, Base):
    """Sensitive merchant KYC media — admin-only; never on public business APIs."""

    __tablename__ = "merchant_documents"

    business_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("businesses.id", ondelete="CASCADE"), nullable=False, index=True
    )
    doc_type: Mapped[str] = mapped_column(String(40), nullable=False, index=True)
    url: Mapped[str] = mapped_column(Text, nullable=False)
    object_key: Mapped[str | None] = mapped_column(String(255))
    mime_type: Mapped[str | None] = mapped_column(String(80))
    meta_json: Mapped[dict | None] = mapped_column("meta", JSON)
    is_current: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    business: Mapped[Business] = relationship("Business", back_populates="kyc_documents")


class BusinessMember(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "business_members"
    __table_args__ = (UniqueConstraint("business_id", "user_id", name="uq_business_member"),)

    business_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("businesses.id", ondelete="CASCADE"), nullable=False
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    role: Mapped[str] = mapped_column(String(20), nullable=False, default=MemberRole.STAFF.value)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)

    business: Mapped[Business] = relationship("Business", back_populates="members")


class Location(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "locations"
    __table_args__ = (
        CheckConstraint("latitude >= -90 AND latitude <= 90", name="ck_lat"),
        CheckConstraint("longitude >= -180 AND longitude <= 180", name="ck_lng"),
    )

    business_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("businesses.id", ondelete="CASCADE"),
        unique=True,
        nullable=False,
    )
    address_line: Mapped[str | None] = mapped_column(String(255))
    city: Mapped[str | None] = mapped_column(String(100), default="Kampala")
    district: Mapped[str | None] = mapped_column(String(100))
    country: Mapped[str] = mapped_column(String(2), nullable=False, default="UG")
    latitude: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    longitude: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))

    business: Mapped[Business] = relationship("Business", back_populates="location")
