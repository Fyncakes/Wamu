"""Airtel Money collection + disbursement adapter unit tests (mocked HTTP)."""

from __future__ import annotations

import base64
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from Crypto.PublicKey import RSA

from app.integrations.payments.airtel_common import (
    collection_accepted,
    encrypt_pin,
    normalize_msisdn,
    parse_transaction_status,
    sign_payload,
)
from app.integrations.payments.disbursement import AirtelDisbursementAdapter
from app.integrations.payments.provider import AirtelAdapter, PaymentInitResult


def _rsa_b64() -> str:
    key = RSA.generate(2048)
    return base64.b64encode(key.publickey().export_key("DER")).decode("ascii")


def test_normalize_msisdn_strips_country_and_zero():
    assert normalize_msisdn("+256752604392") == "752604392"
    assert normalize_msisdn("256752604392") == "752604392"
    assert normalize_msisdn("0752604392") == "752604392"
    assert normalize_msisdn("752604392") == "752604392"


def test_parse_transaction_status_codes():
    assert (
        parse_transaction_status({"data": {"transaction": {"status": "TS"}}})
        == "SUCCESS"
    )
    assert (
        parse_transaction_status({"transaction": {"status": "TF"}}) == "FAILED"
    )
    assert (
        parse_transaction_status({"data": {"transaction": {"status": "TIP"}}})
        == "PENDING"
    )


def test_collection_accepted_success_flag():
    assert collection_accepted(200, {"status": {"success": True, "response_code": "DP00800001001"}})
    assert not collection_accepted(400, {})
    assert not collection_accepted(200, {"status": {"success": False, "message": "fail"}})


def test_encrypt_pin_and_sign_roundtrip_shape():
    pub = _rsa_b64()
    enc = encrypt_pin(pub, "1234")
    assert isinstance(enc, str) and len(enc) > 20
    signed = sign_payload(pub, {"reference": "x", "transaction": {"id": "1"}})
    assert signed.payload.startswith("{")
    assert signed.x_signature
    assert signed.x_key


@pytest.mark.asyncio
async def test_airtel_collection_initiate_signed_v2():
    pub = _rsa_b64()
    settings = MagicMock()
    settings.airtel_client_id = "cid"
    settings.airtel_client_secret = "sec"
    settings.airtel_base_url = "https://openapiuat.airtel.africa"
    settings.airtel_country = "UG"
    settings.airtel_currency = "UGX"
    settings.airtel_sign_collections = True

    token_res = MagicMock(status_code=200)
    token_res.json.return_value = {"access_token": "tok", "expires_in": 180}
    key_res = MagicMock(status_code=200)
    key_res.json.return_value = {"data": {"key": pub}}
    pay_res = MagicMock(status_code=200)
    pay_res.json.return_value = {
        "status": {"success": True, "response_code": "DP00800001001"},
        "data": {"transaction": {"id": "will-be-overridden"}},
    }
    pay_res.text = "{}"

    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock(side_effect=[token_res, pay_res])
    mock_client.get = AsyncMock(return_value=key_res)

    with patch(
        "app.integrations.payments.provider.get_settings", return_value=settings
    ), patch(
        "app.integrations.payments.provider.httpx.AsyncClient",
        return_value=mock_client,
    ):
        result = await AirtelAdapter().initiate_payment(
            amount=Decimal("1000"),
            currency="UGX",
            reference="order-1",
            phone="+256752604392",
        )

    assert isinstance(result, PaymentInitResult)
    assert result.status == "PENDING"
    assert result.provider_reference  # uuid
    # Second post is collection (after token)
    assert mock_client.post.await_count == 2
    _args, kwargs = mock_client.post.await_args_list[1]
    assert "merchant/v2/payments" in _args[0]
    assert "x-signature" in kwargs["headers"]
    assert "x-key" in kwargs["headers"]
    assert "content" in kwargs  # signed raw body


@pytest.mark.asyncio
async def test_airtel_disbursement_requires_pin():
    settings = MagicMock()
    settings.airtel_client_id = "cid"
    settings.airtel_client_secret = "sec"
    settings.airtel_disbursement_pin = ""
    settings.airtel_base_url = "https://openapiuat.airtel.africa"
    settings.airtel_country = "UG"
    settings.airtel_currency = "UGX"

    with patch(
        "app.integrations.payments.disbursement.get_settings", return_value=settings
    ), patch(
        "app.integrations.payments.disbursement.airtel_disbursement_configured",
        return_value=True,
    ):
        with pytest.raises(RuntimeError, match="AIRTEL_DISBURSEMENT_PIN"):
            await AirtelDisbursementAdapter().initiate_disbursement(
                amount=Decimal("500"),
                currency="UGX",
                reference="payout-1",
                payee_phone="+256752604392",
            )


@pytest.mark.asyncio
async def test_airtel_disbursement_v2_encrypted_pin():
    pub = _rsa_b64()
    settings = MagicMock()
    settings.airtel_client_id = "cid"
    settings.airtel_client_secret = "sec"
    settings.airtel_disbursement_pin = "1234"
    settings.airtel_base_url = "https://openapiuat.airtel.africa"
    settings.airtel_country = "UG"
    settings.airtel_currency = "UGX"

    token_res = MagicMock(status_code=200)
    token_res.json.return_value = {"access_token": "tok"}
    key_res = MagicMock(status_code=200)
    key_res.json.return_value = {"data": {"key": pub}}
    disb_res = MagicMock(status_code=200)
    disb_res.json.return_value = {
        "status": {"success": True, "response_code": "DP00900001001"},
        "data": {"transaction": {"id": "x"}},
    }
    disb_res.text = "{}"

    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock(side_effect=[token_res, disb_res])
    mock_client.get = AsyncMock(return_value=key_res)

    with patch(
        "app.integrations.payments.disbursement.get_settings", return_value=settings
    ), patch(
        "app.integrations.payments.disbursement.airtel_disbursement_configured",
        return_value=True,
    ), patch(
        "app.integrations.payments.disbursement.httpx.AsyncClient",
        return_value=mock_client,
    ):
        result = await AirtelDisbursementAdapter().initiate_disbursement(
            amount=Decimal("500"),
            currency="UGX",
            reference="payout-1",
            payee_phone="+256752604392",
        )

    assert result.status == "PENDING"
    _args, kwargs = mock_client.post.await_args_list[1]
    assert "standard/v2/disbursements" in _args[0]
    body = kwargs["json"]
    assert body["payee"]["msisdn"] == "752604392"
    assert body["pin"] != "1234"  # RSA-encrypted
    assert body["transaction"]["type"] == "B2C"
