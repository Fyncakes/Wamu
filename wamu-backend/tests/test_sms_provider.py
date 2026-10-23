"""Africa's Talking OTP delivery — no network."""

import json

import pytest

from app.integrations.sms.provider import (
    LIVE_MESSAGING_URL,
    SANDBOX_MESSAGING_URL,
    messaging_url,
    raise_for_sms_result,
)


def test_sandbox_username_uses_sandbox_host():
    assert messaging_url("sandbox") == SANDBOX_MESSAGING_URL
    assert messaging_url("Sandbox") == SANDBOX_MESSAGING_URL
    assert messaging_url("wamu") == LIVE_MESSAGING_URL


def test_accepted_recipient_does_not_raise():
    body = json.dumps(
        {
            "SMSMessageData": {
                "Message": "Sent to 1/1",
                "Recipients": [
                    {
                        "statusCode": 101,
                        "number": "+256700000099",
                        "status": "Success",
                        "messageId": "ATXid_1",
                    }
                ],
            }
        }
    )
    raise_for_sms_result(201, body)


def test_http_201_with_rejected_recipient_is_a_failure():
    body = json.dumps(
        {
            "SMSMessageData": {
                "Message": "Sent to 0/1",
                "Recipients": [
                    {
                        "statusCode": 403,
                        "number": "+256700000099",
                        "status": "InvalidPhoneNumber",
                    }
                ],
            }
        }
    )
    with pytest.raises(RuntimeError, match="SMS delivery failed"):
        raise_for_sms_result(201, body)


def test_http_error_is_a_failure():
    with pytest.raises(RuntimeError, match="SMS delivery failed"):
        raise_for_sms_result(401, "{}")
