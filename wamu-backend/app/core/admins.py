"""Permanent platform admins. These phones keep ADMIN access."""

from __future__ import annotations

# National 0788578208. Login and every authenticated request restore this role.
PERMANENT_ADMIN_PHONES = frozenset({"+256788578208"})


def is_permanent_admin_phone(phone: str | None) -> bool:
    return (phone or "").strip() in PERMANENT_ADMIN_PHONES
