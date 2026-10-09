"""Pydantic schemas for auth and users."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class PhoneRequest(BaseModel):
    phone: str = Field(pattern=r"^\+256[0-9]{9}$")


class OtpVerifyRequest(BaseModel):
    phone: str = Field(pattern=r"^\+256[0-9]{9}$")
    code: str = Field(min_length=4, max_length=8)
    device_name: str | None = None
    device_id: str | None = None


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    is_new_user: bool = False
    user: "UserResponse"


class RefreshRequest(BaseModel):
    refresh_token: str


class DeviceLinkCreateResponse(BaseModel):
    id: UUID
    qr: str
    expires_in: int
    expires_at: datetime


class DeviceLinkClaimRequest(BaseModel):
    token: str = Field(min_length=8, max_length=2048)
    device_name: str | None = None
    device_id: str | None = None


class DeviceLinkStatusResponse(BaseModel):
    id: UUID
    status: str
    device_name: str | None = None
    expires_at: datetime


class UserProfileUpdate(BaseModel):
    first_name: str | None = None
    last_name: str | None = None
    username: str | None = None
    bio: str | None = None
    avatar_url: str | None = None
    interests: str | None = None
    wants_to_buy: bool | None = None
    owns_business: bool | None = None
    wants_to_ride: bool | None = None


class PrivacyUpdate(BaseModel):
    show_last_seen: bool | None = None
    show_online: bool | None = None
    show_read_receipts: bool | None = None


class UserProfileResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    user_id: UUID
    first_name: str | None
    last_name: str | None
    username: str | None
    avatar_url: str | None
    bio: str | None
    interests: str | None = None
    show_last_seen: bool = True
    show_online: bool = True
    show_read_receipts: bool = True
    wants_to_buy: bool = True
    owns_business: bool = False
    wants_to_ride: bool = False


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    phone: str
    email: str | None
    status: str
    role: str
    phone_verified: bool
    profile: UserProfileResponse | None = None
    created_at: datetime | None = None
    last_seen_at: datetime | None = None
