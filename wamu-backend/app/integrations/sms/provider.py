"""SMS provider abstraction — mock for tests; Africa's Talking when OTP_MOCK_MODE=false."""

from __future__ import annotations

import json
import logging
from abc import ABC, abstractmethod

import httpx

from app.core.config import get_settings

logger = logging.getLogger(__name__)

LIVE_MESSAGING_URL = "https://api.africastalking.com/version1/messaging"
SANDBOX_MESSAGING_URL = "https://api.sandbox.africastalking.com/version1/messaging"
# 100 processed, 101 sent, 102 queued. Anything else did not reach the handset.
_ACCEPTED_STATUS_CODES = {100, 101, 102}


def messaging_url(username: str) -> str:
    if username.strip().lower() == "sandbox":
        return SANDBOX_MESSAGING_URL
    return LIVE_MESSAGING_URL


def raise_for_sms_result(status_code: int, body: str) -> None:
    """Africa's Talking returns HTTP 201 even when the recipient row failed."""
    if status_code >= 400:
        logger.error("Africa's Talking SMS failed http=%s", status_code)
        raise RuntimeError("SMS delivery failed")
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        logger.error("Africa's Talking SMS returned a non-JSON body http=%s", status_code)
        raise RuntimeError("SMS delivery failed") from None
    recipients = (data.get("SMSMessageData") or {}).get("Recipients") or []
    if not recipients:
        logger.error("Africa's Talking SMS returned no recipients http=%s", status_code)
        raise RuntimeError("SMS delivery failed")
    for rec in recipients:
        raw_code = rec.get("statusCode")
        try:
            code_n = int(raw_code)
        except (TypeError, ValueError):
            code_n = -1
        if code_n not in _ACCEPTED_STATUS_CODES:
            logger.error(
                "Africa's Talking rejected SMS status=%s statusCode=%s",
                rec.get("status"),
                raw_code,
            )
            raise RuntimeError("SMS delivery failed")


class SMSProvider(ABC):
    @abstractmethod
    async def send_otp(self, phone: str, code: str) -> None:
        ...


class MockSMSProvider(SMSProvider):
    """Test double. Does not send SMS and does not log the code."""

    async def send_otp(self, phone: str, code: str) -> None:
        _ = code
        logger.info("MOCK SMS OTP skipped for %s (no SMS sent)", phone)


class AfricasTalkingSMSProvider(SMSProvider):
    """Africa's Talking SMS API — never logs the OTP code."""

    def __init__(self, *, username: str, api_key: str, sender_id: str | None = None) -> None:
        self._username = username
        self._api_key = api_key
        self._sender_id = (sender_id or "").strip() or None

    async def send_otp(self, phone: str, code: str) -> None:
        message = f"Your Wamu code is {code}. It expires in a few minutes. Do not share it."
        form: dict[str, str] = {
            "username": self._username,
            "to": phone,
            "message": message,
        }
        # Omit `from` unless a sender ID is set. An unregistered ID is rejected.
        if self._sender_id:
            form["from"] = self._sender_id

        async with httpx.AsyncClient(timeout=20.0) as client:
            res = await client.post(
                messaging_url(self._username),
                headers={
                    "apiKey": self._api_key,
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
                data=form,
            )
        raise_for_sms_result(res.status_code, res.text)
        logger.info("SMS OTP accepted by Africa's Talking for %s", phone)


class UnconfiguredSMSProvider(SMSProvider):
    async def send_otp(self, phone: str, code: str) -> None:
        raise RuntimeError(
            "OTP_MOCK_MODE=false but AFRICASTALKING_USERNAME / AFRICASTALKING_API_KEY "
            "are not set — fill staging secrets or re-enable mock OTP"
        )


def get_sms_provider() -> SMSProvider:
    settings = get_settings()
    if settings.otp_mock_mode:
        return MockSMSProvider()
    username = (settings.africastalking_username or "").strip()
    api_key = (settings.africastalking_api_key or "").strip()
    if username and api_key:
        return AfricasTalkingSMSProvider(
            username=username,
            api_key=api_key,
            sender_id=settings.africastalking_sender_id,
        )
    return UnconfiguredSMSProvider()
