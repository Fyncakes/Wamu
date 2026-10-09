"""Orders and line items — totals computed server-side; item prices are snapshots."""

from __future__ import annotations

import enum
import uuid
from decimal import Decimal
from typing import TYPE_CHECKING

from sqlalchemy import CheckConstraint, ForeignKey, Integer, Numeric, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base
from app.models.mixins import TimestampMixin, UUIDMixin, VersionMixin

if TYPE_CHECKING:
    from app.models.payment import Payment


class OrderStatus(str, enum.Enum):
    PENDING = "PENDING"
    CONFIRMED = "CONFIRMED"
    PROCESSING = "PROCESSING"
    READY = "READY"
    OUT_FOR_DELIVERY = "OUT_FOR_DELIVERY"
    DELIVERED = "DELIVERED"
    CANCELLED = "CANCELLED"
    REFUNDED = "REFUNDED"


# Allowed transitions enforced in the order service (not only in the DB).
ORDER_TRANSITIONS: dict[str, set[str]] = {
    OrderStatus.PENDING.value: {OrderStatus.CONFIRMED.value, OrderStatus.CANCELLED.value},
    OrderStatus.CONFIRMED.value: {OrderStatus.PROCESSING.value, OrderStatus.CANCELLED.value},
    OrderStatus.PROCESSING.value: {OrderStatus.READY.value, OrderStatus.CANCELLED.value},
    OrderStatus.READY.value: {
        OrderStatus.OUT_FOR_DELIVERY.value,
        OrderStatus.DELIVERED.value,
        OrderStatus.CANCELLED.value,
    },
    OrderStatus.OUT_FOR_DELIVERY.value: {OrderStatus.DELIVERED.value, OrderStatus.CANCELLED.value},
    OrderStatus.DELIVERED.value: {OrderStatus.REFUNDED.value},
    OrderStatus.CANCELLED.value: set(),
    OrderStatus.REFUNDED.value: set(),
}


class Order(UUIDMixin, TimestampMixin, VersionMixin, Base):
    __tablename__ = "orders"
    __table_args__ = (
        CheckConstraint("subtotal >= 0", name="orders_subtotal_nonneg"),
        CheckConstraint("delivery_fee >= 0", name="orders_delivery_fee_nonneg"),
        CheckConstraint("total >= 0", name="orders_total_nonneg"),
        CheckConstraint("total = subtotal + delivery_fee", name="orders_total_integrity"),
        CheckConstraint("currency = 'UGX'", name="orders_currency_ugx"),
    )

    customer_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, index=True
    )
    business_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("businesses.id"), nullable=False, index=True
    )
    status: Mapped[str] = mapped_column(
        String(30), nullable=False, default=OrderStatus.PENDING.value, index=True
    )
    subtotal: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False)
    delivery_fee: Mapped[Decimal] = mapped_column(
        Numeric(14, 2), nullable=False, default=Decimal("0")
    )
    total: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="UGX")
    delivery_address: Mapped[str | None] = mapped_column(Text)
    customer_note: Mapped[str | None] = mapped_column(Text)
    fulfillment: Mapped[str] = mapped_column(String(20), nullable=False, default="PICKUP")
    # Shared id when one customer checkout spans multiple merchant sub-orders.
    checkout_batch_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), nullable=True, index=True
    )

    items: Mapped[list[OrderItem]] = relationship(
        "OrderItem", back_populates="order", cascade="all, delete-orphan"
    )
    payment: Mapped[Payment | None] = relationship(
        "Payment", back_populates="order", uselist=False
    )


class OrderItem(UUIDMixin, Base):
    __tablename__ = "order_items"
    __table_args__ = (
        CheckConstraint("quantity > 0", name="order_items_quantity_positive"),
        CheckConstraint("unit_price >= 0", name="order_items_unit_price_nonneg"),
        CheckConstraint("subtotal >= 0", name="order_items_subtotal_nonneg"),
    )

    order_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("orders.id", ondelete="CASCADE"), nullable=False, index=True
    )
    product_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("products.id"), nullable=False
    )
    # Snapshot fields — protect historical orders if product price changes later
    product_name: Mapped[str] = mapped_column(String(200), nullable=False)
    quantity: Mapped[int] = mapped_column(Integer, nullable=False)
    unit_price: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False)
    subtotal: Mapped[Decimal] = mapped_column(Numeric(14, 2), nullable=False)

    order: Mapped[Order] = relationship("Order", back_populates="items")
