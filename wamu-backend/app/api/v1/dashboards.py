"""Dashboard APIs for customer, business, and rider hubs."""

from __future__ import annotations

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.services import dashboards as dash

router = APIRouter()


class BusinessSettingsUpdate(BaseModel):
    name: str | None = Field(default=None, max_length=200)
    phone: str | None = Field(default=None, max_length=20)
    description: str | None = Field(default=None, max_length=2000)
    promo_text: str | None = Field(default=None, max_length=280)


class StaffAdd(BaseModel):
    phone: str = Field(min_length=10, max_length=20)
    role: str = Field(default="STAFF", max_length=20)


class RiderAvailability(BaseModel):
    available_delivery: bool | None = None
    available_rides: bool | None = None


class RiderVehicleUpdate(BaseModel):
    display_name: str | None = Field(default=None, max_length=120)
    vehicle_type: str | None = Field(default=None, max_length=40)
    plate_number: str | None = Field(default=None, max_length=40)


@router.get("/me/payments")
async def my_payments(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await dash.customer_payments(db, user)


@router.get("/me/reviews")
async def my_reviews(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await dash.customer_reviews(db, user)


@router.get("/me/deliveries")
async def my_customer_deliveries(
    user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    return await dash.customer_delivery_history(db, user)


@router.get("/me/following")
async def my_following(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await dash.customer_following(db, user)


@router.get("/business/overview")
async def biz_overview(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await dash.business_overview(db, user)


@router.get("/business/customers")
async def biz_customers(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await dash.business_customers(db, user)


@router.get("/business/staff")
async def biz_staff(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await dash.business_staff(db, user)


@router.post("/business/staff", status_code=201)
async def biz_add_staff(
    body: StaffAdd,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await dash.add_business_staff(db, user, body.phone, body.role)


@router.patch("/business/settings")
async def biz_settings(
    body: BusinessSettingsUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await dash.update_business_settings(
        db,
        user,
        name=body.name,
        phone=body.phone,
        description=body.description,
        promo_text=body.promo_text,
    )


@router.patch("/riders/me/availability")
async def rider_availability(
    body: RiderAvailability,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await dash.set_rider_availability(
        db,
        user,
        available_delivery=body.available_delivery,
        available_rides=body.available_rides,
    )


@router.get("/riders/me/earnings")
async def rider_earnings_ep(
    user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    return await dash.rider_earnings(db, user)


@router.patch("/riders/me/vehicle")
async def rider_vehicle(
    body: RiderVehicleUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await dash.update_rider_vehicle(
        db,
        user,
        vehicle_type=body.vehicle_type,
        plate_number=body.plate_number,
        display_name=body.display_name,
    )
