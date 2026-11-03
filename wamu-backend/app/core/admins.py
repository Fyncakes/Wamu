"""Permanent platform admins. These phones keep ADMIN access."""

from __future__ import annotations

from app.core.phones import normalize_ug_phone

# National 0788578208. Login and every authenticated request restore this role.
PERMANENT_ADMIN_PHONES = frozenset({"+256788578208"})


def is_permanent_admin_phone(phone: str | None) -> bool:
    normalized = normalize_ug_phone(phone) or (phone or "").strip()
    return normalized in PERMANENT_ADMIN_PHONES
