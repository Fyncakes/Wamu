"""MTN partyId normalization for Uganda production."""

from app.integrations.payments.mtn_common import normalize_mtn_msisdn


def test_normalize_mtn_msisdn_uganda_forms():
    assert normalize_mtn_msisdn("0785210393") == "256785210393"
    assert normalize_mtn_msisdn("+256785210393") == "256785210393"
    assert normalize_mtn_msisdn("256785210393") == "256785210393"
    assert normalize_mtn_msisdn("785210393") == "256785210393"
    assert normalize_mtn_msisdn("") == ""
    assert normalize_mtn_msisdn(None) == ""
