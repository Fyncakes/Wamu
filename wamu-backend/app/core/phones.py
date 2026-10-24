"""Uganda MSISDN helpers. Stored accounts use E.164 (+256 and 9 digits)."""

from __future__ import annotations

import re


def normalize_ug_phone(raw: str | None) -> str | None:
    digits = re.sub(r"\D", "", raw or "")
    if not digits:
        return None
    if digits.startswith("256"):
        digits = digits[3:]
    digits = digits.lstrip("0")
    if len(digits) != 9:
        return None
    return f"+256{digits}"
