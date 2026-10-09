"""
Disbursement adapters — transfer to merchant payee MSISDN (non-custodial).

Separate from Collections (`PaymentProvider`). Same mock/staging pattern.
"""

from __future__ import annotations

import logging
import uuid
from abc import ABC, abstractmethod
from decimal import Decimal

import httpx

from app.core.config import get_settings
from app.integrations.payments.provider import PaymentInitResult

logger = logging.getLogger(__name__)


class DisbursementProvider(ABC):
    name: str

    @abstractmethod
    async def initiate_disbursement(
        self,
        *,
        amount: Decimal,
        currency: str,
        reference: str,
        payee_phone: str,
    ) -> PaymentInitResult:
        ...

    @abstractmethod
    async def check_status(self, reference: str) -> PaymentInitResult:
        ...


class MockDisbursementProvider(DisbursementProvider):
    name = "MOCK"

    async def initiate_disbursement(
        self,
        *,
        amount: Decimal,
        currency: str,
        reference: str,
        payee_phone: str,
    ) -> PaymentInitResult:
        settings = get_settings()
        ref = f"MOCK-PAYOUT-{reference}-{uuid.uuid4().hex[:8]}"
        status = "SUCCESS" if settings.payment_mock_auto_success else "PENDING"
        logger.info(
            "MOCK disbursement %s → %s amount=%s %s", ref, payee_phone, amount, status
        )
        return PaymentInitResult(
            provider_reference=ref,
            status=status,
            raw={"mock": True, "payee": payee_phone},
        )

    async def check_status(self, reference: str) -> PaymentInitResult:
        return PaymentInitResult(
            provider_reference=reference, status="SUCCESS", raw={"mock": True}
        )


class NamedMockDisbursementProvider(MockDisbursementProvider):
    def __init__(self, name: str) -> None:
        self.name = name.upper()


class MTNDisbursementAdapter(DisbursementProvider):
    """MTN MoMo Disbursement transfer (sandbox/production)."""

    name = "MTN"

    def _configured(self) -> bool:
        s = get_settings()
        return bool(s.mtn_subscription_key and s.mtn_api_user and s.mtn_api_key)

    async def initiate_disbursement(
        self,
        *,
        amount: Decimal,
        currency: str,
        reference: str,
        payee_phone: str,
    ) -> PaymentInitResult:
        settings = get_settings()
        if not self._configured():
            raise RuntimeError(
                "MTN disbursement credentials missing — set MTN_SUBSCRIPTION_KEY, "
                "MTN_API_USER, MTN_API_KEY (or PAYMENT_MOCK_AUTO_SUCCESS for demos)"
            )
        external_id = str(uuid.uuid4())
        msisdn = (payee_phone or "").lstrip("+")
        url = f"{settings.mtn_base_url.rstrip('/')}/disbursement/v1_0/transfer"
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                token_url = f"{settings.mtn_base_url.rstrip('/')}/disbursement/token/"
                token_res = await client.post(
                    token_url,
                    headers={"Ocp-Apim-Subscription-Key": settings.mtn_subscription_key},
                    auth=(settings.mtn_api_user, settings.mtn_api_key),
                )
                if token_res.status_code >= 400:
                    return PaymentInitResult(
                        provider_reference=external_id,
                        status="FAILED",
                        raw={"token_error": token_res.status_code, "body": token_res.text[:500]},
                    )
                access = token_res.json().get("access_token")
                res = await client.post(
                    url,
                    json={
                        "amount": str(int(amount)),
                        "currency": currency,
                        "externalId": reference[:64],
                        "payee": {"partyIdType": "MSISDN", "partyId": msisdn},
                        "payerMessage": "Wamu merchant payout",
                        "payeeNote": f"Order payout {reference[:20]}",
                    },
                    headers={
                        "Authorization": f"Bearer {access}",
                        "X-Reference-Id": external_id,
                        "X-Target-Environment": settings.mtn_target_environment,
                        "Ocp-Apim-Subscription-Key": settings.mtn_subscription_key,
                        "Content-Type": "application/json",
                    },
                )
                logger.info("MTN disbursement %s → %s", external_id, res.status_code)
                status = "PENDING" if res.status_code in {200, 202} else "FAILED"
                return PaymentInitResult(
                    provider_reference=external_id,
                    status=status,
                    raw={"http_status": res.status_code, "body": res.text[:800]},
                )
        except httpx.HTTPError as exc:
            logger.exception("MTN disbursement failed")
            return PaymentInitResult(
                provider_reference=external_id,
                status="PENDING",
                raw={"error": str(exc)},
            )

    async def check_status(self, reference: str) -> PaymentInitResult:
        settings = get_settings()
        if not self._configured():
            return PaymentInitResult(provider_reference=reference, status="PENDING", raw={})
        url = f"{settings.mtn_base_url.rstrip('/')}/disbursement/v1_0/transfer/{reference}"
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                token_url = f"{settings.mtn_base_url.rstrip('/')}/disbursement/token/"
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


class AirtelDisbursementAdapter(DisbursementProvider):
    """Airtel Money disbursement (Uganda)."""

    name = "AIRTEL"

    def _configured(self) -> bool:
        s = get_settings()
        return bool(s.airtel_client_id and s.airtel_client_secret)

    async def initiate_disbursement(
        self,
        *,
        amount: Decimal,
        currency: str,
        reference: str,
        payee_phone: str,
    ) -> PaymentInitResult:
        settings = get_settings()
        if not self._configured():
            raise RuntimeError(
                "Airtel disbursement credentials missing — set AIRTEL_CLIENT_ID, "
                "AIRTEL_CLIENT_SECRET (or PAYMENT_MOCK_AUTO_SUCCESS for demos)"
            )
        external_id = f"AIRTEL-PAYOUT-{reference}-{uuid.uuid4().hex[:8]}"
        msisdn = (payee_phone or "").lstrip("+")
        url = f"{settings.airtel_base_url.rstrip('/')}/standard/v1/disbursements/"
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
                        provider_reference=external_id,
                        status="FAILED",
                        raw={"token_error": token_res.status_code, "body": token_res.text[:500]},
                    )
                access = token_res.json().get("access_token")
                res = await client.post(
                    url,
                    json={
                        "payee": {
                            "msisdn": msisdn,
                            "currency": currency,
                            "country": "UG",
                        },
                        "reference": external_id,
                        "pin": "",
                        "transaction": {
                            "amount": float(amount),
                            "id": external_id,
                            "type": "B2C",
                        },
                    },
                    headers={
                        "Authorization": f"Bearer {access}",
                        "Content-Type": "application/json",
                        "X-Country": "UG",
                        "X-Currency": currency,
                    },
                )
                logger.info("Airtel disbursement %s → %s", external_id, res.status_code)
                return PaymentInitResult(
                    provider_reference=external_id,
                    status="PENDING" if res.status_code < 300 else "FAILED",
                    raw={"http_status": res.status_code, "body": res.text[:800]},
                )
        except httpx.HTTPError as exc:
            logger.exception("Airtel disbursement failed")
            return PaymentInitResult(
                provider_reference=external_id,
                status="PENDING",
                raw={"error": str(exc)},
            )

    async def check_status(self, reference: str) -> PaymentInitResult:
        # Enquiry endpoints vary; leave PENDING until webhook / dedicated status API
        return PaymentInitResult(provider_reference=reference, status="PENDING", raw={})


def get_disbursement_provider(name: str) -> DisbursementProvider:
    settings = get_settings()
    key = (name or "MOCK").upper()
    if settings.payment_mock_auto_success and key in {"MOCK", "MTN", "AIRTEL"}:
        return NamedMockDisbursementProvider(key)
    mapping: dict[str, DisbursementProvider] = {
        "MOCK": MockDisbursementProvider(),
        "MTN": MTNDisbursementAdapter(),
        "AIRTEL": AirtelDisbursementAdapter(),
    }
    if key not in mapping:
        raise ValueError(f"Unknown disbursement provider: {name}")
    return mapping[key]
