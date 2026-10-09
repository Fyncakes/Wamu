"""SMS provider abstraction — mock for local/dev; Africa's Talking when OTP_MOCK_MODE=false."""

from __future__ import annotations

import logging
from abc import ABC, abstractmethod

import httpx

from app.core.config import get_settings

logger = logging.getLogger(__name__)


class SMSProvider(ABC):
    @abstractmethod
    async def send_otp(self, phone: str, code: str) -> None:
        ...


class MockSMSProvider(SMSProvider):
    """Logs OTP instead of sending SMS. Ideal for local demos."""

    async def send_otp(self, phone: str, code: str) -> None:
        logger.info("MOCK SMS OTP to %s → %s", phone, code)


class AfricasTalkingSMSProvider(SMSProvider):
    """Africa's Talking SMS API — never logs the OTP code."""

    def __init__(self, *, username: str, api_key: str, sender_id: str | None = None) -> None:
        self._username = username
        self._api_key = api_key
        self._sender_id = (sender_id or "").strip() or None

    async def send_otp(self, phone: str, code: str) -> None:
        # Generic body — do not put marketing fluff that leaks the code elsewhere.
        message = f"Your Wamu code is {code}. It expires in a few minutes. Do not share it."
        form: dict[str, str] = {
            "username": self._username,
            "to": phone,
            "message": message,
        }
        if self._sender_id:
            form["from"] = self._sender_id

        async with httpx.AsyncClient(timeout=20.0) as client:
            res = await client.post(
                "https://api.africastalking.com/version1/messaging",
                headers={
                    "apiKey": self._api_key,
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                },
                data=form,
            )
        if res.status_code >= 400:
            logger.error(
                "Africa's Talking SMS failed status=%s body=%s",
                res.status_code,
                res.text[:200],
            )
            raise RuntimeError("SMS delivery failed")
        logger.info("SMS OTP queued via Africa's Talking to %s", phone)


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
