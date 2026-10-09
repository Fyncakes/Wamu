"""In-process product metrics — enough for Phase 0; swap for Prometheus later."""

from __future__ import annotations

import threading
from collections import defaultdict
from typing import Any


class MetricsRegistry:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._counters: dict[str, int] = defaultdict(int)

    def incr(self, name: str, amount: int = 1) -> None:
        with self._lock:
            self._counters[name] += amount

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {"counters": dict(sorted(self._counters.items()))}


metrics = MetricsRegistry()

# Well-known names
PAYMENT_SUCCESS = "payments.success"
PAYMENT_FAILED = "payments.failed"
PAYMENT_INITIATED = "payments.initiated"
PAYOUT_INITIATED = "payouts.initiated"
PAYOUT_SUCCESS = "payouts.success"
PAYOUT_FAILED = "payouts.failed"
WS_CHAT_CONNECT = "ws.chat.connect"
WS_CHAT_DISCONNECT = "ws.chat.disconnect"
WS_CALLS_CONNECT = "ws.calls.connect"
WS_CALLS_DISCONNECT = "ws.calls.disconnect"
HTTP_REQUESTS = "http.requests"
OTP_VERIFY_OK = "auth.otp_verify.ok"
# Master Plan north-star style commerce counters
ORDER_CREATED = "commerce.orders.created"
ORDER_DELIVERED = "commerce.orders.delivered"
DELIVERY_CLAIMED = "commerce.deliveries.claimed"
DELIVERY_COMPLETED = "commerce.deliveries.completed"
REVIEW_CREATED = "commerce.reviews.created"
BUSINESS_CREATED = "commerce.businesses.created"
RIDER_ENROLLED = "commerce.riders.enrolled"
