from app.core.phones import normalize_ug_phone


def test_uganda_numbers_share_one_stored_form():
    assert normalize_ug_phone("0788578208") == "+256788578208"
    assert normalize_ug_phone("788578208") == "+256788578208"
    assert normalize_ug_phone("256788578208") == "+256788578208"
    assert normalize_ug_phone("+256 788 578 208") == "+256788578208"
    assert normalize_ug_phone("+2560788578208") == "+256788578208"


def test_incomplete_numbers_are_rejected():
    assert normalize_ug_phone("") is None
    assert normalize_ug_phone("123") is None
    assert normalize_ug_phone(None) is None
