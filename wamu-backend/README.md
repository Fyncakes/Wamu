# WAMU Backend

Python FastAPI API for the WAMU Uganda Super App MVP.

## Stack

- FastAPI + SQLAlchemy 2 (async) + PostgreSQL (SQLite supported for local demos)
- Redis (rate limits / Celery broker)
- MinIO (product/media images)
- Celery workers (push stubs, reconciliation)

## Quick start (no Docker / SQLite demo)

```bash
cd wamu-backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
./scripts/run_local.sh
```

API docs: http://localhost:8000/docs — mock OTP is always **`123456`**.

## Quick start (Docker + Postgres)

From repo root:

```bash
docker compose -f infrastructure/docker-compose.yml up --build
```

## Auth (mock OTP)

- Request OTP: `POST /api/v1/auth/request-otp` `{"phone":"+2567XXXXXXXX"}`
- Verify: `POST /api/v1/auth/verify-otp` with `{"phone":"...","code":"123456"}`
- Bootstrap admin phone: `+256700000001`

## Seed demo accounts

| Phone | Role |
|-------|------|
| +256700000001 | ADMIN |
| +256700000002 | BUSINESS (FynCakes) |
| +256700000003 | CUSTOMER |

## Tests

```bash
pytest -q
```

## Architecture notes

- Routers are thin; money/authz live in `app/services/`
- Client never dictates order totals or payment amounts
- Payment providers are swappable via `integrations/payments`
- Successful payments are treated as immutable records
