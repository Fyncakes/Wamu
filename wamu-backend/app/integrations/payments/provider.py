"""
Payment provider abstraction.

WAMU does NOT custody customer funds. We initiate provider collections and
reconcile via verified, idempotent webhooks.
"""

from __future__ import annotations

import logging
import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass
from decimal import Decimal

import httpx

from app.core.config import get_settings

logger = logging.getLogger(__name__)


@dataclass
class PaymentInitResult:
    provider_reference: str
    status: str
    raw: dict


class PaymentProvider(ABC):
    name: str

    @abstractmethod
    async def initiate_payment(
        self,
        *,
        amount: Decimal,
        currency: str,
        reference: str,
        phone: str | None,
    ) -> PaymentInitResult:
        ...

    @abstractmethod
    async def check_status(self, reference: str) -> PaymentInitResult:
        ...

    @abstractmethod
    async def refund(self, reference: str) -> PaymentInitResult:
        ...


class MockPaymentProvider(PaymentProvider):
    name = "MOCK"

    async def initiate_payment(
        self,
        *,
        amount: Decimal,
        currency: str,
        reference: str,
        phone: str | None,
    ) -> PaymentInitResult:
        settings = get_settings()
        ref = f"MOCK-{reference}-{uuid.uuid4().hex[:8]}"
        status = "SUCCESS" if settings.payment_mock_auto_success else "PENDING"
        logger.info("MOCK payment %s amount=%s %s → %s", ref, amount, currency, status)
        return PaymentInitResult(provider_reference=ref, status=status, raw={"mock": True})

    async def check_status(self, reference: str) -> PaymentInitResult:
        return PaymentInitResult(
            provider_reference=reference,
            status="SUCCESS",
            raw={"mock": True},
        )

    async def refund(self, reference: str) -> PaymentInitResult:
        return PaymentInitResult(
            provider_reference=reference,
            status="REFUNDED",
            raw={"mock": True},
        )


class NamedMockPaymentProvider(MockPaymentProvider):
    """Demo MoMo theater — same mock success path, labeled MTN / AIRTEL / MOCK."""

    def __init__(self, name: str) -> None:
        self.name = name.upper()


class MTNAdapter(PaymentProvider):
    """
    MTN MoMo Collections (Uganda).

    Staging: set MTN_SUBSCRIPTION_KEY + MTN_API_USER + MTN_API_KEY + MTN_BASE_URL.
    Without credentials, refuses to fake SUCCESS — returns clear config error
    (use PAYMENT_MOCK_AUTO_SUCCESS for local demos).
    """

    name = "MTN"

    def _configured(self) -> bool:
        s = get_settings()
        return bool(s.mtn_subscription_key and s.mtn_api_user and s.mtn_api_key)

    async def initiate_payment(
        self,
        *,
        amount: Decimal,
        currency: str,
        reference: str,
        phone: str | None,
    ) -> PaymentInitResult:
        settings = get_settings()
        if not self._configured():
            raise RuntimeError(
                "MTN MoMo credentials missing — set MTN_SUBSCRIPTION_KEY, "
                "MTN_API_USER, MTN_API_KEY (or enable PAYMENT_MOCK_AUTO_SUCCESS for demos)"
            )
        # Request-to-pay shape; sandbox URLs vary by environment
        external_id = f"MTN-{reference}-{uuid.uuid4().hex[:8]}"
        payload = {
            "amount": str(amount),
            "currency": currency,
            "externalId": external_id,
            "payer": {"partyIdType": "MSISDN", "partyId": (phone or "").lstrip("+")},
            "payerMessage": "Wamu payment",
            "payeeNote": reference,
        }
        headers = {
            "X-Reference-Id": external_id,
            "X-Target-Environment": settings.mtn_target_environment,
            "Ocp-Apim-Subscription-Key": settings.mtn_subscription_key,
            "Content-Type": "application/json",
        }
        # Token + requesttopay — full OAuth is environment-specific; staging hook:
        url = f"{settings.mtn_base_url.rstrip('/')}/collection/v1_0/requesttopay"
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                # Basic auth token endpoint when credentials present
                token_url = f"{settings.mtn_base_url.rstrip('/')}/collection/token/"
                token_res = await client.post(
                    token_url,
                    headers={"Ocp-Apim-Subscription-Key": settings.mtn_subscription_key},
                    auth=(settings.mtn_api_user, settings.mtn_api_key),
                )
                if token_res.status_code >= 400:
                    logger.warning("MTN token failed %s %s", token_res.status_code, token_res.text[:200])
                    return PaymentInitResult(
                        provider_reference=external_id,
                        status="PENDING",
                        raw={"token_error": token_res.status_code, "body": token_res.text[:500]},
                    )
                access = token_res.json().get("access_token")
                headers["Authorization"] = f"Bearer {access}"
                res = await client.post(url, json=payload, headers=headers)
                logger.info("MTN requesttopay %s → %s", external_id, res.status_code)
                return PaymentInitResult(
                    provider_reference=external_id,
                    status="PENDING" if res.status_code in (200, 202) else "FAILED",
                    raw={"http_status": res.status_code, "body": res.text[:800]},
                )
        except httpx.HTTPError as exc:
            logger.exception("MTN initiate failed")
            return PaymentInitResult(
                provider_reference=external_id,
                status="PENDING",
                raw={"error": str(exc)},
            )

    async def check_status(self, reference: str) -> PaymentInitResult:
        settings = get_settings()
        if not self._configured():
            return PaymentInitResult(provider_reference=reference, status="PENDING", raw={})
        url = f"{settings.mtn_base_url.rstrip('/')}/collection/v1_0/requesttopay/{reference}"
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                token_url = f"{settings.mtn_base_url.rstrip('/')}/collection/token/"
                token_res = await client.post(
                    token_url,
                    headers={"Ocp-Apim-Subscription-Key": settings.mtn_subscription_key},
                    auth=(settings.mtn_api_user, settings.mtn_api_key),
                )
                if token_res.status_code >= 400:
                    return PaymentInitResult(
                        provider_reference=reference,
                        status="PENDING",
                        raw={"token_error": token_res.status_code},
                    )
                access = token_res.json().get("access_token")
                res = await client.get(
                    url,
                    headers={
                        "Authorization": f"Bearer {access}",
                        "X-Target-Environment": settings.mtn_target_environment,
                        "Ocp-Apim-Subscription-Key": settings.mtn_subscription_key,
                    },
                )
                try:
                    data = res.json()
                except Exception:
                    data = {"body": res.text[:400]}
                status_raw = str(data.get("status") or "").upper()
                if status_raw in {"SUCCESSFUL", "SUCCESS"}:
                    status = "SUCCESS"
                elif status_raw in {"FAILED", "REJECTED"}:
                    status = "FAILED"
                else:
                    status = "PENDING"
                return PaymentInitResult(
                    provider_reference=reference, status=status, raw=data
                )
        except httpx.HTTPError as exc:
            return PaymentInitResult(
                provider_reference=reference, status="PENDING", raw={"error": str(exc)}
            )

    async def refund(self, reference: str) -> PaymentInitResult:
        raise NotImplementedError("MTN refunds via separate MoMo refund API")


class AirtelAdapter(PaymentProvider):
    """
    Airtel Money collection (Uganda).

    Staging: set AIRTEL_CLIENT_ID + AIRTEL_CLIENT_SECRET + AIRTEL_BASE_URL.
    """

    name = "AIRTEL"

    def _configured(self) -> bool:
        s = get_settings()
        return bool(s.airtel_client_id and s.airtel_client_secret)

    async def initiate_payment(
        self,
        *,
        amount: Decimal,
        currency: str,
        reference: str,
        phone: str | None,
    ) -> PaymentInitResult:
        settings = get_settings()
        if not self._configured():
            raise RuntimeError(
                "Airtel Money credentials missing — set AIRTEL_CLIENT_ID, "
                "AIRTEL_CLIENT_SECRET (or enable PAYMENT_MOCK_AUTO_SUCCESS for demos)"
            )
        external_id = f"AIRTEL-{reference}-{uuid.uuid4().hex[:8]}"
        payload = {
            "reference": external_id,
            "subscriber": {"country": "UG", "currency": currency, "msisdn": (phone or "").lstrip("+")},
            "transaction": {"amount": float(amount), "country": "UG", "currency": currency, "id": external_id},
        }
        url = f"{settings.airtel_base_url.rstrip('/')}/merchant/v1/payments/"
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                # OAuth token
                token_url = f"{settings.airtel_base_url.rstrip('/')}/auth/oauth2/token"
                token_res = await client.post(
                    token_url,
                    data={
                        "client_id": settings.airtel_client_id,
                        "client_secret": settings.airtel_client_secret,
                        "grant_type": "client_credentials",
                    },
                )
                if token_res.status_code >= 400:
                    return PaymentInitResult(
                        provider_reference=external_id,
                        status="PENDING",
                        raw={"token_error": token_res.status_code, "body": token_res.text[:500]},
                    )
                access = token_res.json().get("access_token")
                res = await client.post(
                    url,
                    json=payload,
                    headers={
                        "Authorization": f"Bearer {access}",
                        "Content-Type": "application/json",
                        "X-Country": "UG",
                        "X-Currency": currency,
                    },
                )
                logger.info("Airtel payment %s → %s", external_id, res.status_code)
                return PaymentInitResult(
                    provider_reference=external_id,
                    status="PENDING" if res.status_code < 300 else "FAILED",
                    raw={"http_status": res.status_code, "body": res.text[:800]},
                )
        except httpx.HTTPError as exc:
            logger.exception("Airtel initiate failed")
            return PaymentInitResult(
                provider_reference=external_id,
                status="PENDING",
                raw={"error": str(exc)},
            )

    async def check_status(self, reference: str) -> PaymentInitResult:
        settings = get_settings()
        if not self._configured():
            return PaymentInitResult(provider_reference=reference, status="PENDING", raw={})
        # Airtel enquiry by transaction id
        url = f"{settings.airtel_base_url.rstrip('/')}/standard/v1/payments/{reference}"
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                token_url = f"{settings.airtel_base_url.rstrip('/')}/auth/oauth2/token"
                token_res = await client.post(
                    token_url,
                    data={
                        "client_id": settings.airtel_client_id,
                        "client_secret": settings.airtel_client_secret,
                        "grant_type": "client_credentials",
                    },
                )
                if token_res.status_code >= 400:
                    return PaymentInitResult(
                        provider_reference=reference,
                        status="PENDING",
                        raw={"token_error": token_res.status_code},
                    )
                access = token_res.json().get("access_token")
                res = await client.get(
                    url,
                    headers={
                        "Authorization": f"Bearer {access}",
                        "X-Country": "UG",
                        "X-Currency": "UGX",
                    },
                )
                try:
                    data = res.json()
                except Exception:
                    data = {"body": res.text[:400]}
                # Nested status varies by Airtel API version
                status_raw = str(
                    data.get("status")
                    or (data.get("data") or {}).get("transaction", {}).get("status")
                    or (data.get("data") or {}).get("status")
                    or ""
                ).upper()
                if status_raw in {"TS", "SUCCESS", "SUCCESSFUL", "TIP"}:
                    status = "SUCCESS"
                elif status_raw in {"TF", "FAILED", "FAILURE"}:
                    status = "FAILED"
                else:
                    status = "PENDING"
                return PaymentInitResult(
                    provider_reference=reference, status=status, raw=data
                )
        except httpx.HTTPError as exc:
            return PaymentInitResult(
                provider_reference=reference, status="PENDING", raw={"error": str(exc)}
            )

    async def refund(self, reference: str) -> PaymentInitResult:
        raise NotImplementedError("Airtel refunds via merchant refund API")


def get_payment_provider(name: str) -> PaymentProvider:
    settings = get_settings()
    key = (name or "MOCK").upper()
    if key == "CARD":
        raise ValueError(
            "CARD payments are not supported in MVP — use MTN or AIRTEL Mobile Money"
        )
    # Local / demo: treat MTN & Airtel as labeled mocks so checkout UI can demo both.
    if settings.payment_mock_auto_success and key in {"MOCK", "MTN", "AIRTEL"}:
        return NamedMockPaymentProvider(key)
    mapping: dict[str, PaymentProvider] = {
        "MOCK": MockPaymentProvider(),
        "MTN": MTNAdapter(),
        "AIRTEL": AirtelAdapter(),
    }
    if key not in mapping:
        raise ValueError(f"Unknown payment provider: {name}")
    return mapping[key]
