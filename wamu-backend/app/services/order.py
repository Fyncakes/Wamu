"""
Order service — server calculates totals from line items.

Catalog unit prices are used by default. Business members may set negotiated
unit prices / delivery fees when creating a receipt for a buyer in chat.
"""

from __future__ import annotations

import uuid
from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.audit import AuditLog
from app.models.business import MemberRole
from app.models.notification import Notification
from app.models.order import ORDER_TRANSITIONS, Order, OrderItem, OrderStatus
from app.models.product import Product
from app.models.user import User
from app.schemas.commerce import (
    OrderBatchCreate,
    OrderBatchResponse,
    OrderCreate,
    OrderStatusUpdate,
    ReceiptRevise,
)
from app.services.business import assert_business_member


PICKUP_FEE = Decimal("0")
DELIVERY_FEE_DEFAULT = Decimal("5000")  # UGX flat MVP fee for delivery


def _enqueue_commerce_push(
    *,
    user_id: uuid.UUID,
    title: str,
    body: str,
    data: dict,
) -> None:
    try:
        from app.workers.tasks import send_push_notification

        send_push_notification.delay(
            user_id=str(user_id),
            title=title,
            body=body,
            data=data,
        )
    except Exception:
        pass


async def _is_business_member(db: AsyncSession, user: User, business_id: uuid.UUID) -> bool:
    try:
        await assert_business_member(db, user, business_id)
        return True
    except HTTPException:
        return False


async def _buyer_from_business_chat(
    db: AsyncSession, *, conversation_id: uuid.UUID, business_id: uuid.UUID
) -> uuid.UUID:
    """Pick the customer peer in a CUSTOMER_BUSINESS thread (not shop staff)."""
    from app.models.business import BusinessMember
    from app.models.chat import Conversation

    # get_conversation needs a user — load raw instead
    convo = await db.scalar(
        select(Conversation)
        .options(selectinload(Conversation.members))
        .where(Conversation.id == conversation_id)
    )
    if not convo or convo.business_id != business_id:
        raise HTTPException(status_code=400, detail="Conversation is not this shop's chat")
    staff_ids = set(
        (
            await db.scalars(
                select(BusinessMember.user_id).where(
                    BusinessMember.business_id == business_id,
                    BusinessMember.is_active.is_(True),
                )
            )
        ).all()
    )
    buyers = [m.user_id for m in convo.members if m.user_id not in staff_ids]
    if not buyers:
        raise HTTPException(
            status_code=400,
            detail="No buyer in this chat — open Chat to Order with the customer first",
        )
    return buyers[0]


async def create_order(db: AsyncSession, user: User, data: OrderCreate) -> Order:
    if not data.items:
        raise HTTPException(status_code=400, detail="Order needs items")

    is_staff = await _is_business_member(db, user, data.business_id)
    customer_id = user.id
    merchant_receipt = False

    if data.customer_id is not None and data.customer_id != user.id:
        if not is_staff:
            raise HTTPException(status_code=403, detail="Only the shop can bill a buyer")
        customer_id = data.customer_id
        merchant_receipt = True
    elif is_staff and data.conversation_id is not None:
        # Seller composing a receipt in shop chat — bill the buyer peer.
        customer_id = await _buyer_from_business_chat(
            db, conversation_id=data.conversation_id, business_id=data.business_id
        )
        merchant_receipt = customer_id != user.id

    if merchant_receipt and customer_id == user.id:
        raise HTTPException(status_code=400, detail="Cannot create a receipt for yourself")

    product_ids = [i.product_id for i in data.items]
    result = await db.execute(
        select(Product).where(
            Product.id.in_(product_ids),
            Product.business_id == data.business_id,
            Product.deleted_at.is_(None),
            Product.is_active.is_(True),
        )
    )
    products = {p.id: p for p in result.scalars().all()}
    if len(products) != len(set(product_ids)):
        raise HTTPException(status_code=400, detail="Invalid products for this business")

    subtotal = Decimal("0")
    line_items: list[OrderItem] = []
    for item in data.items:
        product = products[item.product_id]
        if product.stock_quantity is not None and product.stock_quantity < item.quantity:
            raise HTTPException(status_code=400, detail=f"Insufficient stock for {product.name}")
        # Negotiated price only when shop staff creates the receipt.
        if merchant_receipt and item.unit_price is not None:
            unit = Decimal(item.unit_price).quantize(Decimal("0.01"))
        else:
            unit = product.price
        line_sub = (unit * item.quantity).quantize(Decimal("0.01"))
        subtotal += line_sub
        display_name = (item.name or "").strip() or product.name
        line_items.append(
            OrderItem(
                product_id=product.id,
                product_name=display_name[:200],
                quantity=item.quantity,
                unit_price=unit,
                subtotal=line_sub,
            )
        )

    fulfillment = (data.fulfillment or "PICKUP").upper()
    if fulfillment not in {"PICKUP", "DELIVERY"}:
        raise HTTPException(status_code=400, detail="fulfillment must be PICKUP or DELIVERY")
    if fulfillment == "DELIVERY":
        addr = (data.delivery_address or "").strip()
        if len(addr) < 8:
            raise HTTPException(
                status_code=400,
                detail="Delivery address required (e.g. parish / street in Kampala)",
            )
        data.delivery_address = addr

    if merchant_receipt and data.delivery_fee is not None:
        delivery_fee = Decimal(data.delivery_fee).quantize(Decimal("0.01"))
    elif data.checkout_batch_id is not None and data.delivery_fee is not None:
        # Multi-shop batch: fee charged once on first sub-order, 0 on the rest.
        delivery_fee = Decimal(data.delivery_fee).quantize(Decimal("0.01"))
    else:
        delivery_fee = PICKUP_FEE if fulfillment == "PICKUP" else DELIVERY_FEE_DEFAULT
    total = (subtotal + delivery_fee).quantize(Decimal("0.01"))

    order = Order(
        customer_id=customer_id,
        business_id=data.business_id,
        status=OrderStatus.PENDING.value,
        subtotal=subtotal,
        delivery_fee=delivery_fee,
        total=total,
        currency="UGX",
        delivery_address=data.delivery_address,
        customer_note=data.customer_note,
        fulfillment=fulfillment,
        checkout_batch_id=data.checkout_batch_id,
        items=line_items,
    )
    db.add(order)
    await db.flush()

    from app.models.business import Business

    biz = await db.get(Business, data.business_id)
    # Notify the party who did not create the order.
    if merchant_receipt:
        note_data = {"order_id": str(order.id), "type": "RECEIPT_SENT"}
        db.add(
            Notification(
                user_id=customer_id,
                type="RECEIPT_SENT",
                title="Payment receipt from shop",
                body=f"Pay UGX {total} with MoMo — open the chat order card",
                data=note_data,
            )
        )
        _enqueue_commerce_push(
            user_id=customer_id,
            title="Receipt ready — Pay with MoMo",
            body=f"UGX {total} from {biz.name if biz else 'shop'}",
            data=note_data,
        )
    elif biz:
        note_data = {"order_id": str(order.id), "type": "NEW_ORDER"}
        db.add(
            Notification(
                user_id=biz.owner_id,
                type="NEW_ORDER",
                title="New order",
                body=f"New order totaling UGX {total}",
                data=note_data,
            )
        )
        _enqueue_commerce_push(
            user_id=biz.owner_id,
            title="New Wamu order",
            body=f"UGX {total} — open Manage orders",
            data=note_data,
        )
    db.add(
        AuditLog(
            actor_id=user.id,
            action="RECEIPT_CREATED" if merchant_receipt else "ORDER_CREATED",
            entity_type="order",
            entity_id=order.id,
            metadata_json={
                "total": str(total),
                "customer_id": str(customer_id),
                "merchant_receipt": merchant_receipt,
            },
        )
    )
    await db.flush()

    if data.conversation_id:
        await _post_order_card(
            db, user, order, data.conversation_id, merchant_receipt=merchant_receipt
        )

    from app.core.metrics import ORDER_CREATED, metrics

    metrics.incr(ORDER_CREATED)
    return await get_order(db, order.id)


async def create_order_batch(
    db: AsyncSession, user: User, data: OrderBatchCreate
) -> OrderBatchResponse:
    """One customer checkout → N merchant sub-orders sharing checkout_batch_id.

    Delivery fee is charged once (first shop); later shops get 0 so merchant
    product money stays separated while the customer pays one bag total.
    """
    if not data.shops:
        raise HTTPException(status_code=400, detail="Batch needs at least one shop")

    biz_ids = [s.business_id for s in data.shops]
    if len(biz_ids) != len(set(biz_ids)):
        raise HTTPException(status_code=400, detail="Duplicate shops in batch")

    fulfillment = (data.fulfillment or "PICKUP").upper()
    if fulfillment not in {"PICKUP", "DELIVERY"}:
        raise HTTPException(status_code=400, detail="fulfillment must be PICKUP or DELIVERY")
    if fulfillment == "DELIVERY":
        addr = (data.delivery_address or "").strip()
        if len(addr) < 8:
            raise HTTPException(
                status_code=400,
                detail="Delivery address required (e.g. parish / street in Kampala)",
            )
        data.delivery_address = addr

    batch_id = uuid.uuid4()
    orders: list[Order] = []
    for idx, shop in enumerate(data.shops):
        # Charge delivery once across the multi-shop bag.
        fee = None
        if fulfillment == "DELIVERY":
            fee = DELIVERY_FEE_DEFAULT if idx == 0 else Decimal("0")
        else:
            fee = PICKUP_FEE
        sub = await create_order(
            db,
            user,
            OrderCreate(
                business_id=shop.business_id,
                items=shop.items,
                delivery_address=data.delivery_address,
                customer_note=data.customer_note,
                fulfillment=fulfillment,
                delivery_fee=fee,
                checkout_batch_id=batch_id,
            ),
        )
        orders.append(sub)

    subtotal = sum((o.subtotal for o in orders), Decimal("0"))
    delivery_fee = sum((o.delivery_fee for o in orders), Decimal("0"))
    total = sum((o.total for o in orders), Decimal("0"))
    db.add(
        AuditLog(
            actor_id=user.id,
            action="ORDER_BATCH_CREATED",
            entity_type="checkout_batch",
            entity_id=batch_id,
            metadata_json={
                "shop_count": len(orders),
                "total": str(total),
                "order_ids": [str(o.id) for o in orders],
            },
        )
    )
    await db.flush()
    return OrderBatchResponse(
        checkout_batch_id=batch_id,
        orders=orders,
        subtotal=subtotal.quantize(Decimal("0.01")),
        delivery_fee=delivery_fee.quantize(Decimal("0.01")),
        total=total.quantize(Decimal("0.01")),
        currency="UGX",
        shop_count=len(orders),
    )


async def revise_receipt(
    db: AsyncSession, user: User, order_id: uuid.UUID, data: ReceiptRevise
) -> Order:
    """Merchant edits an unpaid PENDING receipt after renegotiation."""
    order = await get_order(db, order_id)
    await assert_business_member(db, user, order.business_id)
    if order.status != OrderStatus.PENDING.value:
        raise HTTPException(status_code=400, detail="Only unpaid pending receipts can be edited")
    from app.models.payment import Payment, PaymentStatus

    payment = await db.scalar(select(Payment).where(Payment.order_id == order.id))
    if payment is not None and payment.status == PaymentStatus.SUCCESS.value:
        raise HTTPException(status_code=400, detail="Receipt already paid")

    product_ids = [i.product_id for i in data.items]
    result = await db.execute(
        select(Product).where(
            Product.id.in_(product_ids),
            Product.business_id == order.business_id,
            Product.deleted_at.is_(None),
            Product.is_active.is_(True),
        )
    )
    products = {p.id: p for p in result.scalars().all()}
    if len(products) != len(set(product_ids)):
        raise HTTPException(status_code=400, detail="Invalid products for this business")

    order.items.clear()
    await db.flush()

    subtotal = Decimal("0")
    for item in data.items:
        product = products[item.product_id]
        unit = (
            Decimal(item.unit_price).quantize(Decimal("0.01"))
            if item.unit_price is not None
            else product.price
        )
        line_sub = (unit * item.quantity).quantize(Decimal("0.01"))
        subtotal += line_sub
        display_name = (item.name or "").strip() or product.name
        order.items.append(
            OrderItem(
                product_id=product.id,
                product_name=display_name[:200],
                quantity=item.quantity,
                unit_price=unit,
                subtotal=line_sub,
            )
        )

    if data.fulfillment:
        fulfillment = data.fulfillment.upper()
        if fulfillment not in {"PICKUP", "DELIVERY"}:
            raise HTTPException(status_code=400, detail="fulfillment must be PICKUP or DELIVERY")
        order.fulfillment = fulfillment
    if data.delivery_address is not None:
        order.delivery_address = data.delivery_address.strip() or None
    if order.fulfillment == "DELIVERY":
        addr = (order.delivery_address or "").strip()
        if len(addr) < 8:
            raise HTTPException(status_code=400, detail="Delivery address required")
        order.delivery_address = addr
    if data.customer_note is not None:
        order.customer_note = data.customer_note
    if data.delivery_fee is not None:
        order.delivery_fee = Decimal(data.delivery_fee).quantize(Decimal("0.01"))
    elif order.fulfillment == "PICKUP":
        order.delivery_fee = PICKUP_FEE

    order.subtotal = subtotal
    order.total = (subtotal + order.delivery_fee).quantize(Decimal("0.01"))
    order.version += 1
    await db.flush()

    db.add(
        Notification(
            user_id=order.customer_id,
            type="RECEIPT_UPDATED",
            title="Receipt updated",
            body=f"New total UGX {order.total} — open chat to pay",
            data={"order_id": str(order.id), "type": "RECEIPT_UPDATED"},
        )
    )
    db.add(
        AuditLog(
            actor_id=user.id,
            action="RECEIPT_REVISED",
            entity_type="order",
            entity_id=order.id,
            metadata_json={"total": str(order.total)},
        )
    )
    await db.flush()
    await refresh_order_cards(db, order)
    return await get_order(db, order.id)


async def _post_order_card(
    db: AsyncSession,
    user: User,
    order: Order,
    conversation_id: uuid.UUID,
    *,
    merchant_receipt: bool = False,
) -> None:
    """Push transactional ORDER_CARD into the merchant chat thread."""
    import json

    from app.models.business import Business
    from app.schemas.commerce import MessageCreate
    from app.services.chat import send_message

    biz = await db.get(Business, order.business_id)
    items_preview = [
        {"name": i.product_name, "qty": i.quantity, "unit_price": str(i.unit_price)}
        for i in (order.items or [])
    ]
    payload = {
        "order_id": str(order.id),
        "business_id": str(order.business_id),
        "business_name": biz.name if biz else "Business",
        "status": order.status,
        "payment_status": "UNPAID",
        "fulfillment": order.fulfillment,
        "subtotal": str(order.subtotal),
        "delivery_fee": str(order.delivery_fee),
        "total": str(order.total),
        "currency": order.currency,
        "delivery_address": order.delivery_address,
        "items": items_preview,
        "pay_cta": "Pay with MoMo",
        "merchant_receipt": merchant_receipt,
        "customer_id": str(order.customer_id),
    }
    await send_message(
        db,
        user,
        conversation_id,
        MessageCreate(
            body=json.dumps(payload),
            message_type="ORDER_CARD",
            client_message_id=f"order-card-{order.id}",
        ),
    )


async def refresh_order_cards_after_payment(db: AsyncSession, order: Order) -> None:
    """Update chat ORDER_CARD payloads so Pay CTA clears after MoMo SUCCESS."""
    await refresh_order_cards(db, order)


async def refresh_order_cards(
    db: AsyncSession, order: Order, *, delivery_status: str | None = None
) -> None:
    """Keep chat ORDER_CARD payloads in sync with order / delivery state."""
    import json

    from app.models.chat import Message
    from app.models.payment import PaymentStatus

    pay_status = "UNPAID"
    from app.models.payment import Payment

    payment = await db.scalar(select(Payment).where(Payment.order_id == order.id))
    if payment is not None:
        pay_status = payment.status

    await db.refresh(order, attribute_names=["items"])

    client_id = f"order-card-{order.id}"
    result = await db.execute(
        select(Message).where(
            Message.message_type == "ORDER_CARD",
            Message.client_message_id == client_id,
        )
    )
    for msg in result.scalars().all():
        try:
            data = json.loads(msg.body)
            if not isinstance(data, dict):
                continue
        except Exception:
            continue
        data["status"] = order.status
        data["payment_status"] = pay_status
        data["subtotal"] = str(order.subtotal)
        data["delivery_fee"] = str(order.delivery_fee)
        data["total"] = str(order.total)
        data["fulfillment"] = order.fulfillment
        data["delivery_address"] = order.delivery_address
        data["items"] = [
            {"name": i.product_name, "qty": i.quantity, "unit_price": str(i.unit_price)}
            for i in (order.items or [])
        ]
        if pay_status == PaymentStatus.SUCCESS.value:
            data["pay_cta"] = "Paid"
        elif pay_status == "UNPAID" or pay_status == PaymentStatus.PENDING.value:
            data["pay_cta"] = "Pay with MoMo"
        if delivery_status:
            data["delivery_status"] = delivery_status
        msg.body = json.dumps(data)
    await db.flush()


_ORDER_STATUS_COPY = {
    "CONFIRMED": "Order confirmed — waiting for the shop",
    "PROCESSING": "Shop is preparing your order",
    "READY": "Order is ready for pickup / rider",
    "OUT_FOR_DELIVERY": "Order is out for delivery",
    "DELIVERED": "Order delivered",
    "CANCELLED": "Order cancelled",
}

_DELIVERY_STATUS_COPY = {
    "ACCEPTED": "Rider assigned",
    "GOING_TO_PICKUP": "Rider is going to the shop",
    "AT_PICKUP": "Rider arrived at the shop",
    "PICKED_UP": "Rider picked up your order",
    "IN_TRANSIT": "Rider is on the way to you",
    "DELIVERED": "Delivered — enjoy!",
    "CANCELLED": "Delivery cancelled",
}


async def find_order_conversation(db: AsyncSession, order: Order):
    """Customer↔business thread for this order, if any."""
    from app.models.chat import Conversation, ConversationMember

    result = await db.execute(
        select(Conversation)
        .join(ConversationMember)
        .where(
            Conversation.business_id == order.business_id,
            ConversationMember.user_id == order.customer_id,
        )
        .limit(1)
    )
    return result.scalars().first()


async def post_order_thread_update(
    db: AsyncSession,
    order: Order,
    *,
    body: str,
    client_suffix: str,
    delivery_status: str | None = None,
) -> None:
    """SYSTEM line + ORDER_CARD refresh in the merchant chat (idempotent)."""
    from datetime import datetime, timezone

    from app.core.realtime import manager
    from app.models.business import Business
    from app.models.chat import Message
    from app.services.chat import serialize_message

    convo = await find_order_conversation(db, order)
    if not convo:
        await refresh_order_cards(db, order, delivery_status=delivery_status)
        return

    biz = await db.get(Business, order.business_id)
    if not biz:
        return

    client_id = f"order-upd-{order.id}-{client_suffix}"[:80]
    existing = await db.scalar(
        select(Message).where(
            Message.conversation_id == convo.id,
            Message.client_message_id == client_id,
            Message.deleted_at.is_(None),
        )
    )
    if existing is None:
        msg = Message(
            conversation_id=convo.id,
            sender_id=biz.owner_id,
            body=body,
            message_type="SYSTEM",
            client_message_id=client_id,
            status="SENT",
        )
        db.add(msg)
        convo.last_message_at = datetime.now(timezone.utc)
        await db.flush()
        try:
            from app.schemas.commerce import MessageResponse

            payload = serialize_message(msg, convo_type=convo.type)
            resp = MessageResponse.model_validate(payload)
            await manager.broadcast(
                str(convo.id),
                {"event": "message.new", **resp.model_dump(mode="json")},
            )
        except Exception:
            pass

    await refresh_order_cards(db, order, delivery_status=delivery_status)


async def notify_order_status_in_chat(db: AsyncSession, order: Order) -> None:
    label = _ORDER_STATUS_COPY.get(order.status, f"Order is now {order.status}")
    await post_order_thread_update(
        db,
        order,
        body=label,
        client_suffix=f"ord-{order.status.lower()}",
    )


async def notify_delivery_status_in_chat(
    db: AsyncSession, order: Order, delivery_status: str, *, rider_name: str | None = None
) -> None:
    label = _DELIVERY_STATUS_COPY.get(delivery_status, f"Delivery: {delivery_status}")
    if delivery_status == "ACCEPTED" and rider_name:
        label = f"Rider assigned — {rider_name}"
    await post_order_thread_update(
        db,
        order,
        body=label,
        client_suffix=f"del-{delivery_status.lower()}",
        delivery_status=delivery_status,
    )


async def commit_order_stock(db: AsyncSession, order: Order) -> None:
    """Decrement inventory after payment SUCCESS (idempotent via order status timing)."""
    for item in order.items or []:
        if item.product_id is None:
            continue
        product = await db.get(Product, item.product_id)
        if product is None or product.stock_quantity is None:
            continue
        if product.stock_quantity < item.quantity:
            raise HTTPException(
                status_code=400,
                detail=f"Insufficient stock for {product.name} at payment time",
            )
        product.stock_quantity -= item.quantity
        product.version += 1
    await db.flush()


async def restock_order(db: AsyncSession, order: Order) -> None:
    """Return inventory when a paid order is cancelled."""
    for item in order.items or []:
        if item.product_id is None:
            continue
        product = await db.get(Product, item.product_id)
        if product is None or product.stock_quantity is None:
            continue
        product.stock_quantity += item.quantity
        product.version += 1
    await db.flush()


async def notify_merchant_order_paid(db: AsyncSession, order: Order) -> None:
    """Alert business owner that an order is paid and ready to fulfill."""
    from app.models.business import Business
    from app.models.chat import Conversation, ConversationMember
    from app.models.notification import Notification

    biz = await db.get(Business, order.business_id)
    if not biz:
        return

    conversation_id = None
    result = await db.execute(
        select(Conversation)
        .join(ConversationMember)
        .where(
            Conversation.business_id == order.business_id,
            ConversationMember.user_id == order.customer_id,
        )
        .limit(1)
    )
    convo = result.scalars().first()
    if convo:
        conversation_id = str(convo.id)

    data = {
        "order_id": str(order.id),
        "business_id": str(order.business_id),
        "total": str(order.total),
        "type": "ORDER_PAID",
    }
    if conversation_id:
        data["conversation_id"] = conversation_id

    db.add(
        Notification(
            user_id=biz.owner_id,
            type="ORDER_PAID",
            title="Order paid — fulfill now",
            body=f"UGX {order.total} paid. Advance the order when ready.",
            data=data,
        )
    )
    _enqueue_commerce_push(
        user_id=biz.owner_id,
        title="Order paid",
        body=f"UGX {order.total} — fulfill now",
        data=data,
    )
    await db.flush()


_ORDER_LOAD = (selectinload(Order.items), selectinload(Order.payment))


async def get_order(db: AsyncSession, order_id: uuid.UUID) -> Order:
    result = await db.execute(
        select(Order).options(*_ORDER_LOAD).where(Order.id == order_id)
    )
    order = result.scalar_one_or_none()
    if not order:
        raise HTTPException(status_code=404, detail="Order not found")
    return order


async def list_customer_orders(db: AsyncSession, user: User) -> list[Order]:
    result = await db.execute(
        select(Order)
        .options(*_ORDER_LOAD)
        .where(Order.customer_id == user.id)
        .order_by(Order.created_at.desc())
    )
    return list(result.scalars().all())


async def list_business_orders(db: AsyncSession, user: User, business_id: uuid.UUID) -> list[Order]:
    await assert_business_member(db, user, business_id)
    result = await db.execute(
        select(Order)
        .options(*_ORDER_LOAD)
        .where(Order.business_id == business_id)
        .order_by(Order.created_at.desc())
    )
    return list(result.scalars().all())


async def update_order_status(
    db: AsyncSession, user: User, order_id: uuid.UUID, data: OrderStatusUpdate
) -> Order:
    order = await get_order(db, order_id)
    # Customer may cancel pending; business/admin may advance states
    is_customer = order.customer_id == user.id
    if not is_customer:
        await assert_business_member(
            db,
            user,
            order.business_id,
            {MemberRole.OWNER.value, MemberRole.MANAGER.value, MemberRole.STAFF.value},
        )

    allowed = ORDER_TRANSITIONS.get(order.status, set())
    if data.status not in allowed:
        raise HTTPException(
            status_code=400,
            detail=f"Cannot transition from {order.status} to {data.status}",
        )
    if is_customer and data.status != OrderStatus.CANCELLED.value:
        raise HTTPException(status_code=403, detail="Customers may only cancel")
    if data.version is not None and data.version != order.version:
        raise HTTPException(status_code=409, detail="Order was modified; refresh and retry")

    # Merchants must not fulfill unpaid orders (payment SUCCESS is source of truth).
    if not is_customer and data.status != OrderStatus.CANCELLED.value:
        from app.models.payment import PaymentStatus

        payment = order.payment
        if payment is None or payment.status != PaymentStatus.SUCCESS.value:
            raise HTTPException(
                status_code=400,
                detail="Order is not paid yet — wait for successful payment",
            )

    order.status = data.status
    order.version += 1

    # Restock + refund + reverse payout when cancelling a paid order.
    if data.status == OrderStatus.CANCELLED.value:
        from app.models.payment import PaymentStatus
        from app.models.rider import Delivery, DeliveryStatus
        from app.services.payout import reverse_payout_for_payment

        payment = order.payment
        if payment is not None and payment.status == PaymentStatus.SUCCESS.value:
            await restock_order(db, order)
            from app.services.payment import attempt_collection_refund

            await attempt_collection_refund(db, payment, reason="order_cancelled")
            await reverse_payout_for_payment(db, payment, reason="order_cancelled")

        delivery = await db.scalar(select(Delivery).where(Delivery.order_id == order.id))
        if (
            delivery is not None
            and delivery.status != DeliveryStatus.DELIVERED.value
            and delivery.status != DeliveryStatus.CANCELLED.value
        ):
            delivery.status = DeliveryStatus.CANCELLED.value
            await notify_delivery_status_in_chat(db, order, DeliveryStatus.CANCELLED.value)
            if delivery.rider_id is not None:
                from app.models.rider import RiderProfile

                rider = await db.get(RiderProfile, delivery.rider_id)
                if rider is not None:
                    db.add(
                        Notification(
                            user_id=rider.user_id,
                            type="DELIVERY_CANCELLED",
                            title="Delivery cancelled",
                            body="An assigned delivery was cancelled",
                            data={
                                "order_id": str(order.id),
                                "delivery_id": str(delivery.id),
                            },
                        )
                    )

    db.add(
        Notification(
            user_id=order.customer_id,
            type="ORDER_STATUS",
            title="Order update",
            body=f"Your order is now {data.status}",
            data={"order_id": str(order.id), "status": data.status},
        )
    )
    await notify_order_status_in_chat(db, order)
    await db.flush()
    _enqueue_commerce_push(
        user_id=order.customer_id,
        title="Wamu order",
        body=f"Order is now {data.status}",
        data={"type": "ORDER_STATUS", "order_id": str(order.id), "status": data.status},
    )
    return await get_order(db, order.id)
