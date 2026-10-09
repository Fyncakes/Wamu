"""Delivery riders + passenger rides (Phase 5 thin MVP)."""

from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.deps import get_current_user
from app.models.user import User
from app.schemas.discover import DeliveryResponse, RideCreate, RideResponse, RiderResponse
from app.services import riders as riders_service

router = APIRouter()


class DeliveryStatusUpdate(BaseModel):
    status: str = Field(min_length=3, max_length=40)
    proof_note: str | None = Field(default=None, max_length=500)
    lat: float | None = None
    lng: float | None = None


class RiderLocationUpdate(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


class RideStatusUpdate(BaseModel):
    status: str = Field(min_length=3, max_length=40)


class RiderEnrollRequest(BaseModel):
    display_name: str = Field(min_length=2, max_length=120)
    vehicle_type: str = Field(default="BODA", max_length=40)
    plate_number: str | None = Field(default=None, max_length=40)
    lat: float | None = None
    lng: float | None = None


class RiderRegisterRequest(BaseModel):
    full_name: str = Field(min_length=2, max_length=120)
    date_of_birth: str | None = None
    nin: str | None = Field(default=None, max_length=40)
    emergency_contact_name: str | None = Field(default=None, max_length=120)
    emergency_contact_phone: str | None = Field(default=None, max_length=20)
    location_text: str | None = Field(default=None, max_length=255)
    vehicle_type: str = Field(default="BODA", max_length=40)
    plate_number: str | None = Field(default=None, max_length=40)
    lat: float | None = None
    lng: float | None = None


class RiderVehicleDocsRequest(BaseModel):
    licence_number: str | None = Field(default=None, max_length=60)
    licence_expiry: str | None = None
    licence_class: str | None = Field(default=None, max_length=40)
    motorcycle_reg: str | None = Field(default=None, max_length=40)
    motorcycle_ownership: str | None = Field(default=None, max_length=255)
    plate_number: str | None = Field(default=None, max_length=40)
    insurance_policy: str | None = Field(default=None, max_length=80)
    insurance_reg: str | None = Field(default=None, max_length=40)
    insurance_valid_from: str | None = None
    insurance_valid_to: str | None = None


class RiderDocumentUpload(BaseModel):
    doc_type: str = Field(min_length=3, max_length=40)
    url: str = Field(min_length=4, max_length=2000)
    object_key: str | None = Field(default=None, max_length=255)
    mime_type: str | None = Field(default=None, max_length=80)
    meta: dict | None = None


@router.get("/riders", response_model=list[RiderResponse])
async def list_riders(db: AsyncSession = Depends(get_db)):
    return await riders_service.list_riders(db)


@router.get("/riders/me", response_model=RiderResponse)
async def my_rider_profile(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from fastapi import HTTPException

    rider = await riders_service.get_my_rider_profile(db, user)
    if not rider:
        raise HTTPException(status_code=404, detail="Not enrolled as a rider")
    return riders_service._rider_resp(rider)


@router.post("/riders/me", response_model=RiderResponse, status_code=201)
async def enroll_rider(
    body: RiderEnrollRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from decimal import Decimal

    rider = await riders_service.enroll_as_rider(
        db,
        user,
        display_name=body.display_name,
        vehicle_type=body.vehicle_type,
        plate_number=body.plate_number,
        lat=Decimal(str(body.lat)) if body.lat is not None else None,
        lng=Decimal(str(body.lng)) if body.lng is not None else None,
    )
    return riders_service._rider_resp(rider)


@router.post("/riders/me/register")
async def register_rider_kyc(
    body: RiderRegisterRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Step 1 — personal information + Rider ID."""
    from app.services import rider_verification as rv

    rider = await rv.register_rider(
        db,
        user,
        full_name=body.full_name,
        date_of_birth=body.date_of_birth,
        nin=body.nin,
        emergency_contact_name=body.emergency_contact_name,
        emergency_contact_phone=body.emergency_contact_phone,
        location_text=body.location_text,
        vehicle_type=body.vehicle_type,
        plate_number=body.plate_number,
        lat=body.lat,
        lng=body.lng,
    )
    payload = await rv.get_my_verification(db, user)
    payload["wamu_rider_ref"] = rider.wamu_rider_ref
    return payload


@router.patch("/riders/me/vehicle-docs")
async def patch_vehicle_docs(
    body: RiderVehicleDocsRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from app.services import rider_verification as rv

    await rv.update_licence_moto_insurance(db, user, **body.model_dump(exclude_unset=True))
    return await rv.get_my_verification(db, user)


@router.post("/riders/me/documents")
async def upload_rider_document(
    body: RiderDocumentUpload,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from app.services import rider_verification as rv

    await rv.upsert_document(
        db,
        user,
        doc_type=body.doc_type,
        url=body.url,
        object_key=body.object_key,
        mime_type=body.mime_type,
        meta=body.meta,
    )
    return await rv.get_my_verification(db, user)


@router.post("/riders/me/submit-verification")
async def submit_rider_verification(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Run AI signals and place application in admin queue."""
    from app.services import rider_verification as rv

    await rv.submit_for_verification(db, user)
    return await rv.get_my_verification(db, user)


@router.get("/riders/me/verification")
async def my_rider_verification(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from app.services import rider_verification as rv

    return await rv.get_my_verification(db, user)


@router.patch("/riders/me/location", response_model=RiderResponse)
async def update_rider_location(
    body: RiderLocationUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    rider = await riders_service.update_rider_location(db, user, lat=body.lat, lng=body.lng)
    return riders_service._rider_resp(rider)


@router.get("/deliveries/mine", response_model=list[DeliveryResponse])
async def my_deliveries(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await riders_service.list_my_deliveries(db, user)


@router.get("/deliveries/open", response_model=list[DeliveryResponse])
async def open_deliveries(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await riders_service.list_open_deliveries(db, user)


@router.post("/deliveries/{delivery_id}/claim", response_model=DeliveryResponse)
async def claim_delivery(
    delivery_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await riders_service.claim_delivery(db, user, delivery_id)


@router.get("/deliveries/by-order/{order_id}", response_model=DeliveryResponse)
async def delivery_for_order(
    order_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await riders_service.get_delivery_for_order(db, user, order_id)


@router.patch("/deliveries/{delivery_id}", response_model=DeliveryResponse)
async def patch_delivery(
    delivery_id: UUID,
    body: DeliveryStatusUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await riders_service.advance_delivery(
        db,
        user,
        delivery_id,
        body.status,
        proof_note=body.proof_note,
        lat=body.lat,
        lng=body.lng,
    )


@router.post("/rides", response_model=RideResponse, status_code=201)
async def request_ride(
    body: RideCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await riders_service.create_ride(db, user, body)


@router.get("/rides", response_model=list[RideResponse])
async def list_my_rides(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await riders_service.my_rides(db, user)


@router.get("/rides/mine-as-rider", response_model=list[RideResponse])
async def list_rides_as_rider(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await riders_service.list_rider_rides(db, user)


@router.get("/rides/{ride_id}", response_model=RideResponse)
async def get_ride(
    ride_id: UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await riders_service.get_ride(db, user, ride_id)


@router.patch("/rides/{ride_id}", response_model=RideResponse)
async def patch_ride(
    ride_id: UUID,
    body: RideStatusUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await riders_service.advance_ride(db, user, ride_id, body.status)
