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
from app.integrations.payments.mtn_common import normalize_mtn_msisdn

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
    async def refund(
        self,
        reference: str,
        *,
        amount: Decimal | None = None,
        currency: str = "UGX",
    ) -> PaymentInitResult:
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

    async def refund(
        self,
        reference: str,
        *,
        amount: Decimal | None = None,
        currency: str = "UGX",
    ) -> PaymentInitResult:
        return PaymentInitResult(
            provider_reference=reference,
            status="REFUNDED",
            raw={"mock": True, "amount": str(amount) if amount is not None else None},
        )


class NamedMockPaymentProvider(MockPaymentProvider):
    """Demo MoMo theater — labeled AIRTEL / MOCK only.

    MTN always uses the live ``MTNAdapter`` (sandbox/production API).
    AIRTEL stays PROCESSING until the client confirms a Wamu-owned OTP
    (see payment_momo_otp_enabled). Plain MOCK still auto-SUCCESS for tests.
    """

    def __init__(self, name: str) -> None:
        self.name = name.upper()

    def _requires_wamu_otp(self) -> bool:
        settings = get_settings()
        return (
            settings.payment_mock_auto_success
            and settings.payment_momo_otp_enabled
            and self.name == "AIRTEL"
        )

    async def initiate_payment(
        self,
        *,
        amount: Decimal,
        currency: str,
        reference: str,
        phone: str | None,
    ) -> PaymentInitResult:
        if self._requires_wamu_otp():
            ref = f"{self.name}-{reference}-{uuid.uuid4().hex[:8]}"
            logger.info(
                "MOCK %s payment %s amount=%s %s → PROCESSING (await Wamu OTP)",
                self.name,
                ref,
                amount,
                currency,
            )
            return PaymentInitResult(
                provider_reference=ref,
                status="PROCESSING",
                raw={"mock": True, "otp_required": True, "provider": self.name},
            )
        return await super().initiate_payment(
            amount=amount, currency=currency, reference=reference, phone=phone
        )

    async def check_status(self, reference: str) -> PaymentInitResult:
        if self._requires_wamu_otp():
            # Do not auto-SUCCESS on refresh — OTP confirm is the gate.
            return PaymentInitResult(
                provider_reference=reference,
                status="PROCESSING",
                raw={"mock": True, "otp_required": True, "provider": self.name},
            )
        return await super().check_status(reference)


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
        # Docs: X-Reference-Id must be UUID v4 (resource id for GET /requesttopay/{id}).
        # Keep Wamu order id in externalId / payeeNote for reconciliation.
        # Sandbox wallet uses EUR; production Uganda uses UGX.
        momo_currency = (
            "EUR" if settings.mtn_target_environment.lower() == "sandbox" else (currency or "UGX")
        )
        resource_id = str(uuid.uuid4())
        external_id = f"WAMU-{reference}"[:64]
        payload = {
            "amount": str(amount),
            "currency": momo_currency,
            "externalId": external_id,
            "payer": {
                "partyIdType": "MSISDN",
                "partyId": normalize_mtn_msisdn(phone),
            },
            "payerMessage": "Enter your MoMo PIN to pay Wamu",
            "payeeNote": reference,
        }
        headers = {
            "X-Reference-Id": resource_id,
            "X-Target-Environment": settings.mtn_target_environment,
            "Ocp-Apim-Subscription-Key": settings.mtn_subscription_key,
            "Content-Type": "application/json",
        }
        pub = (settings.public_api_base or "").rstrip("/")
        callback_url = ""
        if pub and not pub.startswith("http://127.") and not pub.startswith("http://localhost"):
            callback_url = f"{pub}/api/v1/payments/webhooks/MTN"
            headers["X-Callback-Url"] = callback_url
        url = f"{settings.mtn_base_url.rstrip('/')}/collection/v1_0/requesttopay"
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                token_url = f"{settings.mtn_base_url.rstrip('/')}/collection/token/"
                token_res = await client.post(
                    token_url,
                    headers={"Ocp-Apim-Subscription-Key": settings.mtn_subscription_key},
                    auth=(settings.mtn_api_user, settings.mtn_api_key),
                )
                if token_res.status_code >= 400:
                    logger.warning("MTN token failed %s %s", token_res.status_code, token_res.text[:200])
                    return PaymentInitResult(
                        provider_reference=resource_id,
                        status="PENDING",
                        raw={"token_error": token_res.status_code, "body": token_res.text[:500]},
                    )
                access = token_res.json().get("access_token")
                headers["Authorization"] = f"Bearer {access}"
                res = await client.post(url, json=payload, headers=headers)
                # Sandbox API users bind providerCallbackHost at provision time. If
                # PUBLIC_API_BASE host differs (e.g. webhook.site vs Railway), MTN
                # returns 500 INVALID_CALLBACK_URL_HOST — retry without callback;
                # client refresh still polls GET /requesttopay/{id}.
                if (
                    res.status_code >= 400
                    and callback_url
                    and "INVALID_CALLBACK_URL_HOST" in (res.text or "")
                ):
                    logger.warning(
                        "MTN requesttopay %s callback host rejected (%s); retrying without X-Callback-Url",
                        resource_id,
                        res.text[:160],
                    )
                    headers.pop("X-Callback-Url", None)
                    res = await client.post(url, json=payload, headers=headers)
                if res.status_code in (200, 202):
                    logger.info("MTN requesttopay %s → %s", resource_id, res.status_code)
                else:
                    logger.warning(
                        "MTN requesttopay %s → %s %s",
                        resource_id,
                        res.status_code,
                        (res.text or "")[:300],
                    )
                return PaymentInitResult(
                    provider_reference=resource_id,
                    status="PENDING" if res.status_code in (200, 202) else "FAILED",
                    raw={
                        "http_status": res.status_code,
                        "body": res.text[:800],
                        "externalId": external_id,
                        "currency": momo_currency,
                    },
                )
        except httpx.HTTPError as exc:
            logger.exception("MTN initiate failed")
            return PaymentInitResult(
                provider_reference=resource_id,
                status="PENDING",
                raw={"error": str(exc), "externalId": external_id},
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

    async def refund(
        self,
        reference: str,
        *,
        amount: Decimal | None = None,
        currency: str = "UGX",
    ) -> PaymentInitResult:
        """MoMo Collection refund against a prior requesttopay reference."""
        settings = get_settings()
        if not self._configured():
            raise RuntimeError("MTN credentials missing for refund")
        external_id = str(uuid.uuid4())
        url = f"{settings.mtn_base_url.rstrip('/')}/collection/v1_0/refund"
        amt = str(int(amount)) if amount is not None else "0"
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
                        provider_reference=external_id,
                        status="FAILED",
                        raw={
                            "token_error": token_res.status_code,
                            "body": token_res.text[:500],
                        },
                    )
                access = token_res.json().get("access_token")
                headers = {
                    "Authorization": f"Bearer {access}",
                    "X-Reference-Id": external_id,
                    "X-Target-Environment": settings.mtn_target_environment,
                    "Ocp-Apim-Subscription-Key": settings.mtn_subscription_key,
                    "Content-Type": "application/json",
                }
                res = await client.post(
                    url,
                    json={
                        "amount": amt,
                        "currency": currency or "UGX",
                        "externalId": external_id[:64],
                        "payerMessage": "Wamu refund",
                        "payeeNote": "Order refund",
                        "referenceIdToRefund": reference,
                    },
                    headers=headers,
                )
                logger.info("MTN refund %s for %s → %s", external_id, reference, res.status_code)
                status = "PENDING" if res.status_code in {200, 202} else "FAILED"
                return PaymentInitResult(
                    provider_reference=external_id,
                    status=status,
                    raw={"http_status": res.status_code, "body": res.text[:800]},
                )
        except httpx.HTTPError as exc:
            logger.exception("MTN refund failed")
            return PaymentInitResult(
                provider_reference=external_id,
                status="PENDING",
                raw={"error": str(exc)},
            )


class AirtelAdapter(PaymentProvider):
    """
    Airtel Money collection (Uganda) — USSD push via Collection APIs v2.

    Staging: AIRTEL_CLIENT_ID + AIRTEL_CLIENT_SECRET + AIRTEL_BASE_URL.
    Portal: https://developers.airtel.africa (UG → Collection-APIs).
    """

    name = "AIRTEL"

    def _configured(self) -> bool:
        from app.integrations.payments.airtel_common import airtel_configured

        return airtel_configured(get_settings())

    async def initiate_payment(
        self,
        *,
        amount: Decimal,
        currency: str,
        reference: str,
        phone: str | None,
    ) -> PaymentInitResult:
        from app.integrations.payments import airtel_common as ac

        settings = get_settings()
        if not self._configured():
            raise RuntimeError(
                "Airtel Money credentials missing — set AIRTEL_CLIENT_ID, "
                "AIRTEL_CLIENT_SECRET (or enable PAYMENT_MOCK_AUTO_SUCCESS for demos)"
            )
        country, cur = ac.country_currency(settings)
        cur = (currency or cur or "UGX").upper()
        txn_id = ac.new_transaction_id()
        msisdn = ac.normalize_msisdn(phone)
        if not msisdn:
            raise RuntimeError("Airtel collection requires a Uganda MSISDN")
        payload = {
            "reference": f"Wamu {reference}"[:25],
            "subscriber": {
                "country": country,
                "currency": cur,
                "msisdn": msisdn,
            },
            "transaction": {
                "amount": int(amount),
                "country": country,
                "currency": cur,
                "id": txn_id,
            },
        }
        # Prefer v2 (signed); fall back to unsigned v1 if signing unavailable.
        use_sign = bool(getattr(settings, "airtel_sign_collections", True))
        url_v2 = f"{settings.airtel_base_url.rstrip('/')}/merchant/v2/payments/"
        url_v1 = f"{settings.airtel_base_url.rstrip('/')}/merchant/v1/payments/"
        try:
            async with httpx.AsyncClient(timeout=25.0) as client:
                access, token_err = await ac.fetch_access_token(client, settings)
                if not access:
                    return PaymentInitResult(
                        provider_reference=txn_id,
                        status="FAILED",
                        raw=token_err,
                    )
                headers = {
                    "Authorization": f"Bearer {access}",
                    "Content-Type": "application/json",
                    "Accept": "*/*",
                    "X-Country": country,
                    "X-Currency": cur,
                }
                body: str | None = None
                url = url_v2
                if use_sign:
                    pub, key_err = await ac.fetch_encryption_key(
                        client, settings, access
                    )
                    if pub:
                        try:
                            signed = ac.sign_payload(pub, payload)
                            headers["x-signature"] = signed.x_signature
                            headers["x-key"] = signed.x_key
                            body = signed.payload
                        except Exception as exc:
                            logger.warning(
                                "Airtel collection signing failed — unsigned v1: %s",
                                exc,
                            )
                            url = url_v1
                    else:
                        logger.warning(
                            "Airtel encryption key unavailable — unsigned v1: %s",
                            key_err,
                        )
                        url = url_v1
                else:
                    url = url_v1

                if body is not None:
                    res = await client.post(url, content=body.encode("utf-8"), headers=headers)
                else:
                    res = await client.post(url, json=payload, headers=headers)
                try:
                    data = res.json()
                except Exception:
                    data = {"body": res.text[:800]}
                logger.info("Airtel collection %s → %s", txn_id, res.status_code)
                ok = ac.collection_accepted(res.status_code, data)
                return PaymentInitResult(
                    provider_reference=txn_id,
                    status="PENDING" if ok else "FAILED",
                    raw={"http_status": res.status_code, "response": data, "url": url},
                )
        except httpx.HTTPError as exc:
            logger.exception("Airtel initiate failed")
            return PaymentInitResult(
                provider_reference=txn_id,
                status="PENDING",
                raw={"error": str(exc)},
            )

    async def check_status(self, reference: str) -> PaymentInitResult:
        from app.integrations.payments import airtel_common as ac

        settings = get_settings()
        if not self._configured():
            return PaymentInitResult(provider_reference=reference, status="PENDING", raw={})
        country, cur = ac.country_currency(settings)
        url = (
            f"{settings.airtel_base_url.rstrip('/')}/standard/v1/payments/{reference}"
        )
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                access, token_err = await ac.fetch_access_token(client, settings)
                if not access:
                    return PaymentInitResult(
                        provider_reference=reference,
                        status="PENDING",
                        raw=token_err,
                    )
                res = await client.get(
                    url,
                    headers={
                        "Authorization": f"Bearer {access}",
                        "Accept": "*/*",
                        "X-Country": country,
                        "X-Currency": cur,
                    },
                )
                try:
                    data = res.json()
                except Exception:
                    data = {"body": res.text[:400]}
                status = ac.parse_transaction_status(data)
                return PaymentInitResult(
                    provider_reference=reference, status=status, raw=data
                )
        except httpx.HTTPError as exc:
            return PaymentInitResult(
                provider_reference=reference, status="PENDING", raw={"error": str(exc)}
            )

    async def refund(
        self,
        reference: str,
        *,
        amount: Decimal | None = None,
        currency: str = "UGX",
    ) -> PaymentInitResult:
        """Airtel full/partial refund against an airtel_money_id."""
        from app.integrations.payments import airtel_common as ac

        settings = get_settings()
        if not self._configured():
            raise RuntimeError("Airtel credentials missing for refund")
        country, cur = ac.country_currency(settings)
        cur = (currency or cur or "UGX").upper()
        external_id = ac.new_transaction_id()
        url = f"{settings.airtel_base_url.rstrip('/')}/standard/v1/payments/refund"
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                access, token_err = await ac.fetch_access_token(client, settings)
                if not access:
                    return PaymentInitResult(
                        provider_reference=external_id,
                        status="FAILED",
                        raw=token_err,
                    )
                body: dict = {
                    "transaction": {
                        "airtel_money_id": reference,
                        "id": external_id,
                    }
                }
                if amount is not None:
                    body["transaction"]["amount"] = int(amount)
                res = await client.post(
                    url,
                    json=body,
                    headers={
                        "Authorization": f"Bearer {access}",
                        "Content-Type": "application/json",
                        "Accept": "*/*",
                        "X-Country": country,
                        "X-Currency": cur,
                    },
                )
                logger.info("Airtel refund %s → %s", external_id, res.status_code)
                return PaymentInitResult(
                    provider_reference=external_id,
                    status="PENDING" if res.status_code < 300 else "FAILED",
                    raw={"http_status": res.status_code, "body": res.text[:800]},
                )
        except httpx.HTTPError as exc:
            logger.exception("Airtel refund failed")
            return PaymentInitResult(
                provider_reference=external_id,
                status="PENDING",
                raw={"error": str(exc)},
            )


def get_payment_provider(name: str) -> PaymentProvider:
    settings = get_settings()
    key = (name or "MOCK").upper()
    if key == "CARD":
        raise ValueError(
            "CARD payments are not supported in MVP — use MTN or AIRTEL Mobile Money"
        )
    # Local / demo: Airtel (+ plain MOCK) is the labeled mock rail.
    # MTN always hits MTNAdapter — sandbox/live credentials in .env.
    if settings.payment_mock_auto_success and key in {"MOCK", "AIRTEL"}:
        return NamedMockPaymentProvider(key)
    mapping: dict[str, PaymentProvider] = {
        "MOCK": MockPaymentProvider(),
        "MTN": MTNAdapter(),
        "AIRTEL": AirtelAdapter(),
    }
    if key not in mapping:
        raise ValueError(f"Unknown payment provider: {name}")
    return mapping[key]
