"""
Disbursement adapters — transfer to merchant payee MSISDN (non-custodial).

Separate from Collections (`PaymentProvider`). Same mock/staging pattern.
Live MTN/Airtel paths activate when PAYMENT_MOCK_AUTO_SUCCESS=false and
credentials are set — otherwise adapters raise / return FAILED clearly.
"""

from __future__ import annotations

import logging
import uuid
from abc import ABC, abstractmethod
from decimal import Decimal

import httpx

from app.core.config import Settings, get_settings
from app.integrations.payments.mtn_common import normalize_mtn_msisdn
from app.integrations.payments.provider import PaymentInitResult

logger = logging.getLogger(__name__)


def _mtn_disbursement_creds(settings: Settings) -> tuple[str, str, str]:
    """Prefer dedicated Disbursement product keys; fall back to Collections."""
    sub = settings.mtn_disbursement_subscription_key or settings.mtn_subscription_key
    user = settings.mtn_disbursement_api_user or settings.mtn_api_user
    key = settings.mtn_disbursement_api_key or settings.mtn_api_key
    return sub, user, key


def _callback_url(settings: Settings, provider: str) -> str | None:
    base = (settings.public_api_base or "").rstrip("/")
    if not base or "127.0.0.1" in base or "localhost" in base:
        # Providers cannot reach loopback — omit callback; rely on poll/reconcile
        if settings.environment in {"production", "staging"}:
            logger.warning(
                "PUBLIC_API_BASE is local (%s) — disbursement callbacks disabled",
                base or "(empty)",
            )
        return None
    return f"{base}/api/v1/payments/webhooks/{provider.upper()}"


def mtn_disbursement_configured(settings: Settings | None = None) -> bool:
    s = settings or get_settings()
    sub, user, key = _mtn_disbursement_creds(s)
    return bool(sub and user and key)


def airtel_disbursement_configured(settings: Settings | None = None) -> bool:
    s = settings or get_settings()
    return bool(s.airtel_client_id and s.airtel_client_secret)


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
        return mtn_disbursement_configured()

    async def _token(self, client: httpx.AsyncClient, settings: Settings) -> tuple[str | None, dict]:
        sub, user, key = _mtn_disbursement_creds(settings)
        token_url = f"{settings.mtn_base_url.rstrip('/')}/disbursement/token/"
        token_res = await client.post(
            token_url,
            headers={"Ocp-Apim-Subscription-Key": sub},
            auth=(user, key),
        )
        if token_res.status_code >= 400:
            return None, {
                "token_error": token_res.status_code,
                "body": token_res.text[:500],
            }
        return token_res.json().get("access_token"), {}

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
                "MTN disbursement credentials missing — set MTN_DISBURSEMENT_* "
                "(or MTN_SUBSCRIPTION_KEY / MTN_API_USER / MTN_API_KEY)"
            )
        sub, _, _ = _mtn_disbursement_creds(settings)
        external_id = str(uuid.uuid4())
        msisdn = normalize_mtn_msisdn(payee_phone)
        url = f"{settings.mtn_base_url.rstrip('/')}/disbursement/v1_0/transfer"
        callback = _callback_url(settings, "MTN")
        momo_currency = (
            "EUR" if settings.mtn_target_environment.lower() == "sandbox" else (currency or "UGX")
        )
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                access, token_err = await self._token(client, settings)
                if not access:
                    return PaymentInitResult(
                        provider_reference=external_id,
                        status="FAILED",
                        raw=token_err,
                    )
                headers = {
                    "Authorization": f"Bearer {access}",
                    "X-Reference-Id": external_id,
                    "X-Target-Environment": settings.mtn_target_environment,
                    "Ocp-Apim-Subscription-Key": sub,
                    "Content-Type": "application/json",
                }
                if callback:
                    headers["X-Callback-Url"] = callback
                res = await client.post(
                    url,
                    json={
                        "amount": str(int(amount)),
                        "currency": momo_currency,
                        "externalId": reference[:64],
                        "payee": {"partyIdType": "MSISDN", "partyId": msisdn},
                        "payerMessage": "Wamu merchant payout",
                        "payeeNote": f"Order payout {reference[:20]}",
                    },
                    headers=headers,
                )
                logger.info("MTN disbursement %s → %s", external_id, res.status_code)
                status = "PENDING" if res.status_code in {200, 202} else "FAILED"
                return PaymentInitResult(
                    provider_reference=external_id,
                    status=status,
                    raw={
                        "http_status": res.status_code,
                        "body": res.text[:800],
                        "callback_url": callback,
                    },
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
            return PaymentInitResult(
                provider_reference=reference, status="PENDING", raw={}
            )
        sub, _, _ = _mtn_disbursement_creds(settings)
        url = f"{settings.mtn_base_url.rstrip('/')}/disbursement/v1_0/transfer/{reference}"
        try:
            async with httpx.AsyncClient(timeout=20.0) as client:
                access, token_err = await self._token(client, settings)
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
                        "X-Target-Environment": settings.mtn_target_environment,
                        "Ocp-Apim-Subscription-Key": sub,
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
    """Airtel Money B2C disbursement (Uganda) — Disbursement APIs v2 + RSA PIN."""

    name = "AIRTEL"

    def _configured(self) -> bool:
        return airtel_disbursement_configured()

    async def initiate_disbursement(
        self,
        *,
        amount: Decimal,
        currency: str,
        reference: str,
        payee_phone: str,
    ) -> PaymentInitResult:
        from app.integrations.payments import airtel_common as ac

        settings = get_settings()
        if not self._configured():
            raise RuntimeError(
                "Airtel disbursement credentials missing — set AIRTEL_CLIENT_ID, "
                "AIRTEL_CLIENT_SECRET"
            )
        pin = (settings.airtel_disbursement_pin or "").strip()
        if not pin:
            raise RuntimeError(
                "AIRTEL_DISBURSEMENT_PIN required for Airtel B2C "
                "(set in developers.airtel.africa → Disbursement PIN)"
            )
        country, cur = ac.country_currency(settings)
        cur = (currency or cur or "UGX").upper()
        txn_id = ac.new_transaction_id()
        msisdn = ac.normalize_msisdn(payee_phone)
        if not msisdn:
            raise RuntimeError("Airtel disbursement requires a Uganda MSISDN")
        url = f"{settings.airtel_base_url.rstrip('/')}/standard/v2/disbursements/"
        try:
            async with httpx.AsyncClient(timeout=25.0) as client:
                access, token_err = await ac.fetch_access_token(client, settings)
                if not access:
                    return PaymentInitResult(
                        provider_reference=txn_id,
                        status="FAILED",
                        raw=token_err,
                    )
                pub, key_err = await ac.fetch_encryption_key(client, settings, access)
                if not pub:
                    return PaymentInitResult(
                        provider_reference=txn_id,
                        status="FAILED",
                        raw=key_err,
                    )
                try:
                    enc_pin = ac.encrypt_pin(pub, pin)
                except Exception as exc:
                    logger.exception("Airtel PIN encryption failed")
                    return PaymentInitResult(
                        provider_reference=txn_id,
                        status="FAILED",
                        raw={"pin_encrypt_error": str(exc)},
                    )
                res = await client.post(
                    url,
                    json={
                        "payee": {
                            "msisdn": msisdn,
                            "currency": cur,
                        },
                        "reference": f"Wamu {reference}"[:25],
                        "pin": enc_pin,
                        "transaction": {
                            "amount": int(amount),
                            "id": txn_id,
                            "type": "B2C",
                        },
                    },
                    headers={
                        "Authorization": f"Bearer {access}",
                        "Content-Type": "application/json",
                        "Accept": "*/*",
                        "X-Country": country,
                        "X-Currency": cur,
                    },
                )
                try:
                    data = res.json()
                except Exception:
                    data = {"body": res.text[:800]}
                logger.info("Airtel disbursement %s → %s", txn_id, res.status_code)
                ok = res.status_code < 300 and (
                    not isinstance(data.get("status"), dict)
                    or data["status"].get("success") is not False
                )
                return PaymentInitResult(
                    provider_reference=txn_id,
                    status="PENDING" if ok else "FAILED",
                    raw={"http_status": res.status_code, "response": data},
                )
        except httpx.HTTPError as exc:
            logger.exception("Airtel disbursement failed")
            return PaymentInitResult(
                provider_reference=txn_id,
                status="PENDING",
                raw={"error": str(exc)},
            )

    async def check_status(self, reference: str) -> PaymentInitResult:
        from app.integrations.payments import airtel_common as ac

        settings = get_settings()
        if not self._configured():
            return PaymentInitResult(
                provider_reference=reference, status="PENDING", raw={}
            )
        country, cur = ac.country_currency(settings)
        url = (
            f"{settings.airtel_base_url.rstrip('/')}/standard/v1/disbursements/"
            f"{reference}"
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
                    data = {"body": res.text[:400], "http_status": res.status_code}
                status = ac.parse_transaction_status(data)
                return PaymentInitResult(
                    provider_reference=reference, status=status, raw=data
                )
        except httpx.HTTPError as exc:
            return PaymentInitResult(
                provider_reference=reference, status="PENDING", raw={"error": str(exc)}
            )


def get_disbursement_provider(name: str) -> DisbursementProvider:
    settings = get_settings()
    key = (name or "MOCK").upper()
    # Airtel (+ MOCK) mock theater; MTN always uses live disbursement adapter.
    if settings.payment_mock_auto_success and key in {"MOCK", "AIRTEL"}:
        return NamedMockDisbursementProvider(key)
    mapping: dict[str, DisbursementProvider] = {
        "MOCK": MockDisbursementProvider(),
        "MTN": MTNDisbursementAdapter(),
        "AIRTEL": AirtelDisbursementAdapter(),
    }
    if key not in mapping:
        raise ValueError(f"Unknown disbursement provider: {name}")
    return mapping[key]
