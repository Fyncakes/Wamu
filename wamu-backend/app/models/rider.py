"""Riders, deliveries, rides, and KYC verification documents."""

from __future__ import annotations

import enum
import uuid
from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import Boolean, Date, DateTime, ForeignKey, Integer, JSON, Numeric, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import SoftDeleteMixin, TimestampMixin, UUIDMixin


class RiderStatus(str, enum.Enum):
    """Application / account lifecycle for delivery riders."""

    DRAFT = "DRAFT"  # registration started, docs incomplete
    SUBMITTED = "SUBMITTED"  # submitted; AI ran
    UNDER_REVIEW = "UNDER_REVIEW"  # in admin verification queue
    NEEDS_REUPLOAD = "NEEDS_REUPLOAD"  # admin requested new docs
    APPROVED = "APPROVED"  # Wamu verified — can go online
    REJECTED = "REJECTED"
    SUSPENDED = "SUSPENDED"


class RiderDocType(str, enum.Enum):
    NATIONAL_ID_FRONT = "NATIONAL_ID_FRONT"
    NATIONAL_ID_BACK = "NATIONAL_ID_BACK"
    LICENCE_FRONT = "LICENCE_FRONT"
    LICENCE_BACK = "LICENCE_BACK"
    MOTORCYCLE = "MOTORCYCLE"
    INSURANCE = "INSURANCE"
    SELFIE = "SELFIE"


class RiderAiResult(str, enum.Enum):
    PASS = "PASS"
    REVIEW = "REVIEW"
    FAIL = "FAIL"


class DeliveryStatus(str, enum.Enum):
    REQUESTED = "REQUESTED"
    ACCEPTED = "ACCEPTED"
    GOING_TO_PICKUP = "GOING_TO_PICKUP"
    AT_PICKUP = "AT_PICKUP"
    PICKED_UP = "PICKED_UP"
    IN_TRANSIT = "IN_TRANSIT"
    DELIVERED = "DELIVERED"
    CANCELLED = "CANCELLED"


class RideStatus(str, enum.Enum):
    REQUESTED = "REQUESTED"
    ACCEPTED = "ACCEPTED"
    EN_ROUTE_PICKUP = "EN_ROUTE_PICKUP"
    AT_PICKUP = "AT_PICKUP"
    IN_TRANSIT = "IN_TRANSIT"
    COMPLETED = "COMPLETED"
    CANCELLED = "CANCELLED"


class RiderProfile(UUIDMixin, TimestampMixin, SoftDeleteMixin, Base):
    __tablename__ = "rider_profiles"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), unique=True, nullable=False, index=True
    )
    display_name: Mapped[str] = mapped_column(String(120), nullable=False)
    photo_url: Mapped[str | None] = mapped_column(Text)
    wamu_rider_ref: Mapped[str] = mapped_column(String(40), unique=True, nullable=False)
    vehicle_type: Mapped[str] = mapped_column(String(40), nullable=False, default="BODA")
    plate_number: Mapped[str | None] = mapped_column(String(40))
    status: Mapped[str] = mapped_column(String(20), nullable=False, default=RiderStatus.DRAFT.value)
    available_delivery: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    available_rides: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    rating: Mapped[Decimal] = mapped_column(Numeric(3, 2), nullable=False, default=Decimal("5.00"))
    delivery_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    ride_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    # Simulated live location (Kampala)
    lat: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    lng: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))

    # —— KYC / personal (admin-only; never expose to customers) ——
    date_of_birth: Mapped[date | None] = mapped_column(Date)
    nin: Mapped[str | None] = mapped_column(String(40))  # National ID number
    emergency_contact_name: Mapped[str | None] = mapped_column(String(120))
    emergency_contact_phone: Mapped[str | None] = mapped_column(String(20))
    location_text: Mapped[str | None] = mapped_column(String(255))

    # Licence / motorcycle / insurance structured fields
    licence_number: Mapped[str | None] = mapped_column(String(60))
    licence_expiry: Mapped[date | None] = mapped_column(Date)
    licence_class: Mapped[str | None] = mapped_column(String(40))  # e.g. A / motorcycle
    motorcycle_reg: Mapped[str | None] = mapped_column(String(40))
    motorcycle_ownership: Mapped[str | None] = mapped_column(String(255))
    insurance_policy: Mapped[str | None] = mapped_column(String(80))
    insurance_reg: Mapped[str | None] = mapped_column(String(40))
    insurance_valid_from: Mapped[date | None] = mapped_column(Date)
    insurance_valid_to: Mapped[date | None] = mapped_column(Date)

    # AI verification signals (not government proof)
    ai_result: Mapped[str | None] = mapped_column(String(20))
    ai_checks: Mapped[dict | None] = mapped_column(JSON)
    ai_ran_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    # Admin review
    admin_note: Mapped[str | None] = mapped_column(Text)
    rejection_reason: Mapped[str | None] = mapped_column(Text)
    reupload_fields: Mapped[list | None] = mapped_column(JSON)  # doc types / field keys
    submitted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    reviewed_by_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=True
    )

    user = relationship("User", foreign_keys=[user_id])
    documents = relationship(
        "RiderDocument",
        back_populates="rider",
        cascade="all, delete-orphan",
        lazy="selectin",
    )


class RiderDocument(UUIDMixin, TimestampMixin, Base):
    """Sensitive rider KYC media — admin-only; never returned on public rider APIs."""

    __tablename__ = "rider_documents"

    rider_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("rider_profiles.id"), nullable=False, index=True
    )
    doc_type: Mapped[str] = mapped_column(String(40), nullable=False, index=True)
    url: Mapped[str] = mapped_column(Text, nullable=False)
    object_key: Mapped[str | None] = mapped_column(String(255))
    mime_type: Mapped[str | None] = mapped_column(String(80))
    meta_json: Mapped[dict | None] = mapped_column("meta", JSON)
    # Soft-replace on reupload: keep history by marking superseded
    is_current: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    rider = relationship("RiderProfile", back_populates="documents")


class Delivery(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "deliveries"

    order_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("orders.id"), unique=True, nullable=False, index=True
    )
    rider_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("rider_profiles.id"), nullable=True, index=True
    )
    status: Mapped[str] = mapped_column(
        String(30), nullable=False, default=DeliveryStatus.REQUESTED.value
    )
    pickup_address: Mapped[str | None] = mapped_column(Text)
    dropoff_address: Mapped[str | None] = mapped_column(Text)
    pickup_lat: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    pickup_lng: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    dropoff_lat: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    dropoff_lng: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    rider_lat: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    rider_lng: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    fee: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False, default=Decimal("3000"))
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="UGX")
    eta_minutes: Mapped[int | None] = mapped_column(Integer)
    proof_note: Mapped[str | None] = mapped_column(Text)
    # Same value across multi-shop pickups for one customer checkout.
    delivery_batch_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), nullable=True, index=True
    )

    order = relationship("Order")
    rider = relationship("RiderProfile")


class Ride(UUIDMixin, TimestampMixin, Base):
    __tablename__ = "rides"

    customer_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True
    )
    rider_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("rider_profiles.id"), nullable=True, index=True
    )
    status: Mapped[str] = mapped_column(
        String(30), nullable=False, default=RideStatus.REQUESTED.value
    )
    pickup_address: Mapped[str] = mapped_column(Text, nullable=False)
    dropoff_address: Mapped[str] = mapped_column(Text, nullable=False)
    pickup_lat: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    pickup_lng: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    dropoff_lat: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    dropoff_lng: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    rider_lat: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    rider_lng: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    fare: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False, default=Decimal("8000"))
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="UGX")
    eta_minutes: Mapped[int | None] = mapped_column(Integer)

    customer = relationship("User")
    rider = relationship("RiderProfile")
