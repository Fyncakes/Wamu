#!/bin/sh
# Staging/production API entrypoint: migrate → seed → serve
set -eu

echo "[wamu] waiting for database…"
i=0
until python - <<'PY'
import asyncio, os, sys
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy import text

url = os.environ.get("DATABASE_URL", "")
if not url:
    sys.exit(1)

async def main():
    eng = create_async_engine(url)
    async with eng.connect() as c:
        await c.execute(text("SELECT 1"))
    await eng.dispose()

asyncio.run(main())
PY
do
  i=$((i + 1))
  if [ "$i" -ge 30 ]; then
    echo "[wamu] database not ready" >&2
    exit 1
  fi
  sleep 2
done

echo "[wamu] alembic upgrade head…"
python -m alembic upgrade head

echo "[wamu] bootstrap seed…"
python -m scripts.bootstrap

echo "[wamu] starting uvicorn…"
exec uvicorn app.main:app --host 0.0.0.0 --port 8000
