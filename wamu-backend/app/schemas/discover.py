"""Discover videos + rider / delivery schemas (commerce + later discovery)."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class DiscoverVideoResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    business_id: UUID
    business_name: str
    business_logo_url: str | None = None
    author_id: UUID
    caption: str | None = None
    video_url: str
    poster_url: str | None = None
    tags: str | None = None
    like_count: int = 0
    comment_count: int = 0
    view_count: int = 0
    liked_by_me: bool = False
    following: bool = False
    product_id: UUID | None = None
    product_name: str | None = None
    product_price: Decimal | None = None
    currency: str = "UGX"
    status: str = "active"
    file_size_bytes: int | None = None
    created_at: datetime | None = None


class VideoCreate(BaseModel):
    business_id: UUID
    caption: str | None = Field(default=None, max_length=500)
    video_url: str = Field(min_length=4, max_length=2000)
    poster_url: str | None = None
    original_video_url: str | None = None
    tags: str | None = None
    product_id: UUID | None = None
    file_size_bytes: int | None = Field(default=None, ge=0)
    duration_seconds: int | None = Field(
        default=None,
        ge=1,
        le=90,
        description="Clip length in seconds (Discover shorts: max 1.5 minutes)",
    )


class VideoRetentionSettings(BaseModel):
    archive_after_days: int = Field(ge=30, le=730, description="Days before Active → Archived")
    purge_after_days: int = Field(
        ge=60, le=1825, description="Days before Archived → Permanently deleted"
    )


class RiderResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    display_name: str
    photo_url: str | None = None
    wamu_rider_ref: str
    vehicle_type: str
    plate_number: str | None = None
    status: str
    rating: Decimal
    delivery_count: int
    ride_count: int
    available_delivery: bool
    available_rides: bool
    lat: Decimal | None = None
    lng: Decimal | None = None
    # Own-profile only — omit on public rider cards if not loaded
    payout_phone: str | None = None
    payout_provider: str | None = None
    preferred_min_per_km_ugx: Decimal | None = None


class RiderPayoutSettingsUpdate(BaseModel):
    payout_phone: str = Field(..., pattern=r"^\+256[0-9]{9}$")
    payout_provider: str = Field(default="MTN", pattern="^(MTN|AIRTEL|MOCK)$")


class DeliveryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    order_id: UUID
    rider_id: UUID | None = None
    status: str
    pickup_address: str | None = None
    dropoff_address: str | None = None
    pickup_lat: Decimal | None = None
    pickup_lng: Decimal | None = None
    dropoff_lat: Decimal | None = None
    dropoff_lng: Decimal | None = None
    rider_lat: Decimal | None = None
    rider_lng: Decimal | None = None
    fee: Decimal
    currency: str
    eta_minutes: int | None = None
    proof_note: str | None = None
    shop_name: str | None = None
    rider: RiderResponse | None = None
    created_at: datetime | None = None
    distance_km: Decimal | None = None
    estimated_fee: Decimal | None = None
    agreed_fee: Decimal | None = None


class RideCreate(BaseModel):
    pickup_address: str = Field(min_length=4, max_length=400)
    dropoff_address: str = Field(min_length=4, max_length=400)
    pickup_lat: Decimal | None = None
    pickup_lng: Decimal | None = None
    dropoff_lat: Decimal | None = None
    dropoff_lng: Decimal | None = None


class RideResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    customer_id: UUID
    rider_id: UUID | None = None
    status: str
    pickup_address: str
    dropoff_address: str
    rider_lat: Decimal | None = None
    rider_lng: Decimal | None = None
    fare: Decimal
    currency: str
    eta_minutes: int | None = None
    rider: RiderResponse | None = None
    created_at: datetime | None = None
