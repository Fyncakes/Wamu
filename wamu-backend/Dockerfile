FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN chmod +x /app/scripts/entrypoint.sh

ENV PYTHONPATH=/app
EXPOSE 8000

# Migrate (Alembic) → seed → serve
CMD ["/app/scripts/entrypoint.sh"]
