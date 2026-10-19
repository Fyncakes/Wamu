#!/usr/bin/env python3
"""Create MTN MoMo sandbox API User + API Key from subscription keys in env.

Portal operations (Sandbox User Provisioning):
  POST https://sandbox.momodeveloper.mtn.com/v1_0/apiuser
  GET  https://sandbox.momodeveloper.mtn.com/v1_0/apiuser/{X-Reference-Id}
  POST https://sandbox.momodeveloper.mtn.com/v1_0/apiuser/{X-Reference-Id}/apikey

Docs:
  https://momodeveloper.mtn.com/API-collections#api=sandbox-provisioning-api&operation=post-v1_0-apiuser
  https://momodeveloper.mtn.com/API-collections#api=sandbox-provisioning-api&operation=get-v1_0-apiuser
  https://momodeveloper.mtn.com/API-collections#api=sandbox-provisioning-api&operation=post-v1_0-apiuser-apikey

Usage (from wamu-backend):
  python scripts/provision_mtn_sandbox.py

Requires MTN_SUBSCRIPTION_KEY (and optionally MTN_DISBURSEMENT_SUBSCRIPTION_KEY).
Writes MTN_API_USER / MTN_API_KEY (and disbursement pair) into .env when MTN returns 201.

providerCallbackHost must be a hostname (e.g. webhook.site), not a full URL path —
X-Callback-Url on requesttopay must use the same host.

If MTN returns HTTP 500, the sandbox is down — not a Wamu bug.
"""
from __future__ import annotations

import json
import os
import uuid
from pathlib import Path
from urllib import error, request
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
ENV_PATH = ROOT / ".env"
BASE = os.environ.get("MTN_BASE_URL", "https://sandbox.momodeveloper.mtn.com").rstrip("/")


def load_dotenv(path: Path) -> dict[str, str]:
    vals: dict[str, str] = {}
    if not path.exists():
        return vals
    for line in path.read_text().splitlines():
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        vals[k.strip()] = v.strip().strip('"').strip("'")
    return vals


def _callback_host() -> str:
    """Hostname only — matches MTN providerCallbackHost rules."""
    raw = os.environ.get("MTN_CALLBACK_HOST") or ""
    if not raw:
        env = load_dotenv(ENV_PATH)
        pub = env.get("PUBLIC_API_BASE") or os.environ.get("PUBLIC_API_BASE") or ""
        if pub:
            host = urlparse(pub).hostname or pub
            if host and host not in {"127.0.0.1", "localhost"}:
                return host
        return "webhook.site"
    if "://" in raw:
        return urlparse(raw).hostname or raw
    return raw.split("/")[0]


def upsert_dotenv(path: Path, updates: dict[str, str]) -> None:
    text = path.read_text() if path.exists() else ""
    lines = text.splitlines()
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        if not line or line.lstrip().startswith("#") or "=" not in line:
            out.append(line)
            continue
        k, _, _ = line.partition("=")
        if k in updates:
            out.append(f"{k}={updates[k]}")
            seen.add(k)
        else:
            out.append(line)
    for k, v in updates.items():
        if k not in seen:
            out.append(f"{k}={v}")
    path.write_text("\n".join(out) + "\n")


def http(method: str, url: str, headers: dict[str, str], body: dict | None = None):
    data = None if body is None else json.dumps(body).encode()
    req = request.Request(url, data=data, method=method)
    for k, v in headers.items():
        req.add_header(k, v)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with request.urlopen(req, timeout=30) as res:
            return res.status, res.read().decode()
    except error.HTTPError as e:
        return e.code, (e.read().decode() if e.fp else "")


def provision(subscription_key: str, token_path: str) -> tuple[str, str]:
    """Sandbox User Provisioning: create user → get user → create apikey → token."""
    import base64

    callback = _callback_host()
    user_id = str(uuid.uuid4())
    print(f"  X-Reference-Id (API User) = {user_id}")
    print(f"  providerCallbackHost = {callback}")

    # 1) POST /v1_0/apiuser
    status, raw = http(
        "POST",
        f"{BASE}/v1_0/apiuser",
        {
            "X-Reference-Id": user_id,
            "Ocp-Apim-Subscription-Key": subscription_key,
        },
        {"providerCallbackHost": callback},
    )
    print(f"  POST /v1_0/apiuser → {status} {raw[:200]}")
    if status not in (200, 201):
        raise SystemExit(
            f"MTN create apiuser failed ({status}). "
            "Open portal Sandbox User Provisioning → post-v1_0-apiuser, "
            "or retry when MTN sandbox recovers."
        )

    # 2) GET /v1_0/apiuser/{X-Reference-Id}  (cannot return apiKey)
    status, raw = http(
        "GET",
        f"{BASE}/v1_0/apiuser/{user_id}",
        {"Ocp-Apim-Subscription-Key": subscription_key},
    )
    print(f"  GET  /v1_0/apiuser/{{id}} → {status} {raw[:200]}")
    if status not in (200, 201):
        raise SystemExit(f"MTN get apiuser failed ({status})")

    # 3) POST /v1_0/apiuser/{X-Reference-Id}/apikey
    status, raw = http(
        "POST",
        f"{BASE}/v1_0/apiuser/{user_id}/apikey",
        {"Ocp-Apim-Subscription-Key": subscription_key},
    )
    print(f"  POST /v1_0/apiuser/{{id}}/apikey → {status} {raw[:200]}")
    if status not in (200, 201):
        raise SystemExit(f"MTN create apikey failed ({status})")
    api_key = json.loads(raw)["apiKey"]

    basic = base64.b64encode(f"{user_id}:{api_key}".encode()).decode()
    status, raw = http(
        "POST",
        f"{BASE}{token_path}",
        {
            "Ocp-Apim-Subscription-Key": subscription_key,
            "Authorization": f"Basic {basic}",
        },
    )
    print(f"  token {token_path} → {status} {raw[:120]}")
    if status not in (200, 201) or "access_token" not in raw:
        raise SystemExit("Token check failed — credentials may be wrong")
    return user_id, api_key


def main() -> None:
    env = load_dotenv(ENV_PATH)
    col = env.get("MTN_SUBSCRIPTION_KEY") or os.environ.get("MTN_SUBSCRIPTION_KEY")
    dis = env.get("MTN_DISBURSEMENT_SUBSCRIPTION_KEY") or os.environ.get(
        "MTN_DISBURSEMENT_SUBSCRIPTION_KEY"
    )
    if not col:
        raise SystemExit("Set MTN_SUBSCRIPTION_KEY in .env first")
    print(f"Base: {BASE}")
    print("Provisioning Collections…")
    user, key = provision(col, "/collection/token/")
    updates = {"MTN_API_USER": user, "MTN_API_KEY": key}
    if dis:
        print("Provisioning Disbursements…")
        duser, dkey = provision(dis, "/disbursement/token/")
        updates["MTN_DISBURSEMENT_API_USER"] = duser
        updates["MTN_DISBURSEMENT_API_KEY"] = dkey
    upsert_dotenv(ENV_PATH, updates)
    staging = ROOT.parent / "infrastructure" / ".env.staging"
    if staging.exists():
        upsert_dotenv(staging, updates)
    print(f"Wrote API user/key into {ENV_PATH}")


if __name__ == "__main__":
    main()
