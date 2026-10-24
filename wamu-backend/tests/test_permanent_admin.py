from types import SimpleNamespace

from app.core.admins import is_permanent_admin_phone
from app.services.auth import _grant_permanent_admin


def test_owner_phone_is_permanent_admin():
    assert is_permanent_admin_phone("+256788578208")
    assert is_permanent_admin_phone("0788578208") is False
    assert is_permanent_admin_phone("+256700000001") is False


def test_grant_restores_admin_and_active_status():
    user = SimpleNamespace(phone="+256788578208", role="CUSTOMER", status="SUSPENDED")
    _grant_permanent_admin(user)
    assert user.role == "ADMIN"
    assert user.status == "ACTIVE"


def test_grant_leaves_other_accounts_alone():
    user = SimpleNamespace(phone="+256700000099", role="CUSTOMER", status="ACTIVE")
    _grant_permanent_admin(user)
    assert user.role == "CUSTOMER"
    assert user.status == "ACTIVE"
