FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN chmod +x /app/scripts/entrypoint.sh /app/scripts/entrypoint_celery.sh

ENV PYTHONPATH=/app
# Cloud Run sets PORT (often 8080); local compose uses 8000
EXPOSE 8000 8080

# Migrate (Alembic) → seed → serve
CMD ["/app/scripts/entrypoint.sh"]
