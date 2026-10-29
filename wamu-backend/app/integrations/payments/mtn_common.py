"""Shared MTN MoMo helpers (Collections + Disbursement)."""

from __future__ import annotations

import re


def normalize_mtn_msisdn(phone: str | None, *, default_cc: str = "256") -> str:
    """MTN partyId: digits only with country code (e.g. 256785210393).

    Production rejects ``078…`` / ``+256…``; sandbox is looser but we normalize
    everywhere so Railway → production is a config flip only.
    """
    raw = re.sub(r"\D", "", phone or "")
    if not raw:
        return ""
    if raw.startswith("0") and len(raw) == 10:
        raw = default_cc + raw[1:]
    elif len(raw) == 9 and raw.startswith("7"):
        raw = default_cc + raw
    return raw
