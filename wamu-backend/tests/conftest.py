import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


async def complete_mock_momo_payment(
    client: Any,
    headers: dict[str, str],
    pay_body: dict[str, Any],
) -> dict[str, Any]:
    """If MTN/Airtel mock returns PROCESSING + otp_required, confirm with mock_hint."""
    if pay_body.get("status") != "PROCESSING" or not pay_body.get("otp_required"):
        return pay_body
    code = pay_body.get("mock_hint") or "123456"
    ok = await client.post(
        f"/api/v1/payments/{pay_body['id']}/confirm-otp",
        headers=headers,
        json={"code": code},
    )
    assert ok.status_code == 200, ok.text
    return ok.json()
