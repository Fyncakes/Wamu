"""Business, category, location, product schemas."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class CategoryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    slug: str
    description: str | None
    icon_url: str | None
    parent_id: UUID | None
    is_active: bool


class LocationCreate(BaseModel):
    address_line: str | None = None
    city: str | None = "Kampala"
    district: str | None = None
    latitude: Decimal | None = None
    longitude: Decimal | None = None


class LocationResponse(LocationCreate):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    country: str = "UG"


class BusinessCreate(BaseModel):
    name: str = Field(min_length=2, max_length=200)
    category_id: UUID | None = None
    description: str | None = None
    phone: str | None = Field(default=None, pattern=r"^\+256[0-9]{9}$")
    payout_phone: str | None = Field(default=None, pattern=r"^\+256[0-9]{9}$")
    payout_provider: str | None = Field(default=None, pattern=r"^(MOCK|MTN|AIRTEL)$")
    email: str | None = None
    location: LocationCreate | None = None


class BusinessUpdate(BaseModel):
    name: str | None = None
    description: str | None = None
    phone: str | None = None
    payout_phone: str | None = Field(default=None, pattern=r"^\+256[0-9]{9}$")
    payout_provider: str | None = Field(default=None, pattern=r"^(MOCK|MTN|AIRTEL)$")
    email: str | None = None
    category_id: UUID | None = None
    logo_url: str | None = None
    cover_url: str | None = None
    location: LocationCreate | None = None


class BusinessResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    owner_id: UUID
    name: str
    slug: str
    description: str | None
    phone: str | None
    payout_phone: str | None = None
    payout_provider: str | None = None
    email: str | None
    category_id: UUID | None
    status: str
    verification_status: str
    logo_url: str | None
    cover_url: str | None
    rating: Decimal
    review_count: int
    location: LocationResponse | None = None
    created_at: datetime | None = None


class ProductCreate(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    description: str | None = None
    price: Decimal = Field(ge=0)
    currency: str = "UGX"
    stock_quantity: int | None = Field(default=None, ge=0)
    category_id: UUID | None = None


class ProductUpdate(BaseModel):
    name: str | None = None
    description: str | None = None
    price: Decimal | None = Field(default=None, ge=0)
    stock_quantity: int | None = None
    status: str | None = None
    is_active: bool | None = None
    category_id: UUID | None = None


class ProductImageResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    url: str
    is_primary: bool
    sort_order: int


class ProductResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    business_id: UUID
    category_id: UUID | None
    name: str
    slug: str
    description: str | None
    price: Decimal
    currency: str
    stock_quantity: int | None
    status: str
    is_active: bool
    images: list[ProductImageResponse] = []
    created_at: datetime | None = None
