"""Order, payment, chat, review, notification, report, AI schemas."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator


class OrderItemCreate(BaseModel):
    product_id: UUID
    quantity: int = Field(gt=0)
    # Negotiated / bargained unit price (merchant receipt). Catalog price used if omitted.
    unit_price: Decimal | None = Field(default=None, ge=0)
    # Optional display name override for the receipt line
    name: str | None = Field(default=None, min_length=1, max_length=200)


class OrderCreate(BaseModel):
    business_id: UUID
    items: list[OrderItemCreate] = Field(min_length=1)
    delivery_address: str | None = None
    customer_note: str | None = None
    fulfillment: str = "PICKUP"
    # Merchant may set bargained delivery fee; customers cannot override server fee.
    delivery_fee: Decimal | None = Field(default=None, ge=0)
    # When set, posts an ORDER_CARD into this business chat (transactional chat)
    conversation_id: UUID | None = None
    # Merchant creating a receipt for the buyer (must be business member).
    # If omitted with conversation_id, inferred as the non-staff chat peer.
    customer_id: UUID | None = None
    checkout_batch_id: UUID | None = None


class OrderBatchShopCreate(BaseModel):
    business_id: UUID
    items: list[OrderItemCreate] = Field(min_length=1)


class OrderBatchCreate(BaseModel):
    """One customer checkout → one sub-order per merchant."""

    shops: list[OrderBatchShopCreate] = Field(min_length=1)
    fulfillment: str = "PICKUP"
    delivery_address: str | None = None
    customer_note: str | None = None


class ReceiptRevise(BaseModel):
    """Edit an unpaid PENDING receipt (merchant only)."""

    items: list[OrderItemCreate] = Field(min_length=1)
    delivery_address: str | None = None
    customer_note: str | None = None
    fulfillment: str | None = None
    delivery_fee: Decimal | None = Field(default=None, ge=0)


class OrderItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    product_id: UUID
    product_name: str
    quantity: int
    unit_price: Decimal
    subtotal: Decimal


class OrderResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    customer_id: UUID
    business_id: UUID
    status: str
    subtotal: Decimal
    delivery_fee: Decimal
    total: Decimal
    currency: str
    delivery_address: str | None
    customer_note: str | None
    fulfillment: str
    checkout_batch_id: UUID | None = None
    items: list[OrderItemResponse] = []
    created_at: datetime | None = None
    payment_status: str | None = None
    payment_provider: str | None = None

    @model_validator(mode="wrap")
    @classmethod
    def _pull_payment(cls, data: Any, handler):
        payment = None
        if not isinstance(data, dict):
            payment = getattr(data, "payment", None)
        elif "payment" in data and isinstance(data.get("payment"), dict):
            payment = data["payment"]
        result = handler(data)
        if payment is None:
            return result
        status = getattr(payment, "status", None)
        provider = getattr(payment, "provider", None)
        if isinstance(payment, dict):
            status = payment.get("status", status)
            provider = payment.get("provider", provider)
        return result.model_copy(
            update={"payment_status": status, "payment_provider": provider}
        )


class OrderBatchResponse(BaseModel):
    checkout_batch_id: UUID
    orders: list[OrderResponse]
    subtotal: Decimal
    delivery_fee: Decimal
    total: Decimal
    currency: str = "UGX"
    shop_count: int


class OrderStatusUpdate(BaseModel):
    status: str
    version: int | None = None


class PaymentCreate(BaseModel):
    order_id: UUID
    provider: str = "MOCK"
    phone: str | None = Field(default=None, pattern=r"^\+256[0-9]{9}$")
    idempotency_key: str = Field(min_length=8, max_length=100)


class PaymentResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    order_id: UUID
    user_id: UUID
    amount: Decimal
    currency: str
    provider: str
    provider_reference: str | None
    status: str
    created_at: datetime | None = None


class MerchantPayoutResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    payment_id: UUID
    order_id: UUID
    business_id: UUID
    amount: Decimal
    platform_fee: Decimal = Decimal("0.00")
    fee_bps: int = 0
    currency: str
    provider: str
    provider_reference: str | None
    payee_phone: str
    status: str
    created_at: datetime | None = None


class WebhookPayload(BaseModel):
    event_id: str
    provider_reference: str
    status: str
    amount: Decimal | None = None
    currency: str | None = "UGX"
    raw: dict | None = None
    kind: str | None = None  # "disbursement" | "collection" (optional hint)

class ConversationCreate(BaseModel):
    """Start business chat OR peer DM. Provide one of business_id / peer_user_id / peer_phone."""

    business_id: UUID | None = None
    peer_user_id: UUID | None = None
    peer_phone: str | None = None
    initial_message: str | None = Field(default=None, max_length=4000)


class MessageCreate(BaseModel):
    body: str = Field(default="", max_length=4000)
    message_type: str = "TEXT"
    media_url: str | None = None
    reply_to_message_id: UUID | None = None
    # Outbox idempotency — same client_message_id from same sender returns existing row
    client_message_id: str | None = Field(default=None, max_length=80)


class MessageReactionCreate(BaseModel):
    emoji: str = Field(min_length=1, max_length=16)


class MessageAck(BaseModel):
    status: str = Field(description="DELIVERED or READ")


class MessageBulkDelete(BaseModel):
    message_ids: list[UUID] = Field(min_length=1, max_length=50)
    # me = local hide; everyone = silent unsend of own messages (no placeholder).
    scope: Literal["me", "everyone"] = "everyone"


class MessageReplyPreview(BaseModel):
    id: UUID
    body: str
    sender_id: UUID
    message_type: str
    sender_name: str | None = None


class MessageResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    conversation_id: UUID
    sender_id: UUID
    body: str
    message_type: str
    media_url: str | None = None
    client_message_id: str | None = None
    status: str
    created_at: datetime
    reactions: dict[str, int] = Field(default_factory=dict)
    reply_to_message_id: UUID | None = None
    reply_to: MessageReplyPreview | None = None


class ConversationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    type: str
    business_id: UUID | None
    last_message_at: datetime | None
    unread_count: int = 0
    participant_name: str | None = None
    participant_phone: str | None = None
    peer_user_id: UUID | None = None
    last_message_preview: str | None = None
    last_message_from_me: bool = False
    last_message_status: str | None = None
    title: str | None = None
    community_slug: str | None = None
    member_count: int = 0
    muted: bool = False
    pinned: bool = False
    archived: bool = False
    favourite: bool = False
    peer_online: bool = False
    peer_last_seen_at: datetime | None = None
    participant_avatar_url: str | None = None
    participant_avatar_urls: list[str] = Field(default_factory=list)


class ConversationPrefsUpdate(BaseModel):
    muted: bool | None = None
    pinned: bool | None = None
    archived: bool | None = None
    favourite: bool | None = None


class ConversationRename(BaseModel):
    title: str = Field(min_length=2, max_length=200)


class GroupCreate(BaseModel):
    title: str = Field(min_length=2, max_length=200)
    member_phones: list[str] = Field(default_factory=list)
    initial_message: str | None = Field(default=None, max_length=4000)


class ReviewCreate(BaseModel):
    business_id: UUID
    rating: int = Field(ge=1, le=5)
    comment: str | None = None
    order_id: UUID  # verified delivery required
    rider_rating: int | None = Field(default=None, ge=1, le=5)


class ReviewReply(BaseModel):
    reply: str = Field(min_length=1, max_length=2000)


class ReviewResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    business_id: UUID
    user_id: UUID
    order_id: UUID | None = None
    rating: int
    comment: str | None
    reply: str | None
    rider_id: UUID | None = None
    rider_rating: int | None = None
    created_at: datetime | None = None


class NotificationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    type: str
    title: str
    body: str
    data: dict | None
    is_read: bool
    created_at: datetime


class ReportCreate(BaseModel):
    target_type: str
    target_id: UUID
    reason: str
    description: str | None = None


class ReportResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    reporter_id: UUID
    target_type: str
    target_id: UUID
    reason: str
    description: str | None
    status: str
    resolution_note: str | None = None
    created_at: datetime | None = None


class ReportResolve(BaseModel):
    status: str = "RESOLVED"
    resolution_note: str | None = None


class OrderDisputeCreate(BaseModel):
    order_id: UUID
    reason: str = Field(min_length=3, max_length=100)
    description: str | None = Field(default=None, max_length=2000)


class OrderDisputeResolve(BaseModel):
    status: str = Field(description="RESOLVED_REFUND | RESOLVED_REJECT | DISMISSED")
    resolution_note: str | None = None


class OrderDisputeResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    order_id: UUID
    customer_id: UUID
    reason: str
    description: str | None
    status: str
    resolution_note: str | None = None
    resolved_by_id: UUID | None = None
    resolved_at: datetime | None = None
    created_at: datetime | None = None


class AISearchRequest(BaseModel):
    query: str = Field(min_length=2, max_length=500)
    latitude: Decimal | None = None
    longitude: Decimal | None = None


class AISearchResponse(BaseModel):
    interpretation: str
    businesses: list[dict]
    products: list[dict]


class AdminStats(BaseModel):
    users: int
    businesses: int
    orders: int
    payments: int
    riders: int = 0
    riders_pending: int = 0
    riders_approved: int = 0
    open_reports: int = 0
    open_disputes: int = 0
    pending_verifications: int = 0
    # Successful collection GMV (customer paid)
    revenue_ugx: float = 0
    # Non-custodial platform cut retained in MoMo float
    platform_fee_ugx: float = 0
    # Net disbursed to merchants (SUCCESS payouts)
    payout_net_ugx: float = 0
    successful_payouts: int = 0
    # Order status histogram for ops dashboard
    orders_by_status: dict[str, int] = Field(default_factory=dict)
    # Payment status histogram
    payments_by_status: dict[str, int] = Field(default_factory=dict)


class PaginatedMeta(BaseModel):
    total: int
    page: int
    page_size: int
